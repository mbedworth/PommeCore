# MeshCoreApple — Final Complete TODO
## For Claude Code — Work Through in Priority Order

**Project:** ~/Developer/MeshCoreApple
**Git:** Private repo on GitHub (commit and push after each major fix)
**Last Updated:** March 14, 2026

> **Session note (2026-03-22):** This file captures the original comprehensive task list from
> March 14. A separate Build 39 bug-fix session resolved 8 UI/architecture bugs (iOS sheet
> dismissal, macOS inspector done button, App Lock wiring, Share All Channels, Tip Jar macOS
> presentation, Tip Jar product reload, Publishing warnings, ERR 6 alerts). See `BUILD_STATUS.md`
> for full details. The bugs listed below are the *remaining* work from the original task list
> and have not been triaged against the current codebase state.

---

## PRIORITY 1: BLOCKING BUGS

### 1.1 Radio/Broadcast Icon Disconnects Instead of Its Intended Function
**Symptom:** Clicking the radio/broadcast icon ((•)) in the toolbar after connecting disconnects the radio at the app level but NOT at the Bluetooth level. This leaves the BLE connection orphaned — the app shows disconnected but Bluetooth is still connected, so rescanning can't find the device.
**Fix:**
- The radio/broadcast icon should NOT disconnect. It should either: (a) send a self-advertisement (CMD_SEND_SELF_ADVERT), or (b) open the scanner/discover sheet, or (c) do nothing if already connected
- Only the explicit "Disconnect" button (in settings or context menu) should disconnect
- When disconnect IS intentional: call `centralManager.cancelPeripheralConnection(peripheral)`, wait for the `didDisconnectPeripheral` delegate callback, clear all local state (connectedPeripheral = nil, NUS characteristics = nil), then automatically start scanning so the user can reconnect immediately

### 1.2 Clicking "Connected" Status Bar Opens Scanner Instead of Device Info
**Symptom:** When you tap/click the "Connected — MeshCore-5ABD36F5" status bar at the top of the sidebar, it opens the BLE scanner to search for another radio. This is confusing and could lead to accidental disconnection.
**Fix:**
- When connected and user taps the status bar: show a device info popover/sheet with basic info about the currently connected device (name, firmware, battery, signal strength, uptime). Do NOT open the scanner.
- The scanner should ONLY open when there is NO radio connected.
- When disconnected and user taps the status bar: THEN open the scanner to find a radio.
- Before scanning: make sure any existing BLE connection is fully terminated so the correct radio can be found.
- Logic:
```swift
func onStatusBarTapped() {
    if isConnected {
        // Show device info popover — name, firmware, battery, signal
        showDeviceInfoPopover = true
    } else {
        // No radio connected — open scanner
        showScannerSheet = true
    }
}
```

### 1.3 BLE Disconnect Not Clean
**Symptom:** After any disconnect (intentional or accidental), rescanning fails to find the device because the BLE connection wasn't properly terminated.
**Fix:**
- On disconnect: `centralManager.cancelPeripheralConnection(peripheral)`
- Clear: connectedPeripheral = nil, nusRXCharacteristic = nil, nusTXCharacteristic = nil
- Clear all pending ACKs, CLI commands, login states
- Wait for `centralManager(_:didDisconnectPeripheral:error:)` callback
- Then automatically start scanning with a 2-second delay
- For unexpected disconnects (error != nil): attempt auto-reconnect 3 times with 2-second intervals before giving up and starting scan

### 1.3 Contacts Disappear During Remote Admin Fetch
**Symptom:** When logged into a room server/repeater and CLI responses come in, the sidebar contact list goes empty.
**Fix:** Atomic swap pattern for contact sync:
```swift
private var pendingContacts: [Contact] = []

func handleContactsStart(count: Int) {
    pendingContacts = []  // clear BUFFER only, not displayed contacts
}

func handleContact(contact: Contact) {
    pendingContacts.append(contact)
}

func handleEndOfContacts(lastmod: UInt32) {
    DispatchQueue.main.async {
        self.contacts = self.pendingContacts  // atomic swap — one UI update
        self.pendingContacts = []
        self.lastContactSyncMod = lastmod
    }
}
```
- ONLY trigger CMD_GET_CONTACTS from: initial connection, PUSH_CODE_ADVERT (0x80), PUSH_CODE_PATH_UPDATED (0x81), or manual refresh button
- NEVER trigger contact re-sync from CLI response handling or message sync

### 1.4 Compiler Warnings (3 total — still present)
**Fix all of these:**
1. **"'nonisolated(unsafe)' is unnecessary for a constant with 'Sendable' type 'Logger', consider removing it"** in MeshCoreViewModel.swift
   - The previous fix added nonisolated(unsafe) but Logger is already Sendable so it's unnecessary
   - Fix: Simply remove the `nonisolated(unsafe)` keyword — just use `static let logger = Logger(...)`
2. **"The app icon set 'AppIcon' has 2 unassigned children"** in Assets.xcassets
   - Now shows 2 unassigned children (was 1 before)
   - Fix: Open AppIcon.appiconset/Contents.json and remove ALL entries that don't have a corresponding PNG file on disk. Every "filename" field must point to an actual file in the .appiconset directory. If there are image entries with no file, delete the entry. The simplest approach:
     - List all actual PNG files in the AppIcon.appiconset directory
     - Rebuild Contents.json to reference ONLY those files
     - For Xcode 15+ single-size icon, you need just one 1024x1024 PNG with a universal entry
3. **"The app icon set 'AppIcon' has an unassigned child"** — same root cause as above, fix together

### 1.5 Room Server Name Missing in Chat Header
**Symptom:** When viewing a room server chat, the room server name is missing or not displayed properly in the chat header.
**Fix:** When a room server contact is selected and the chat view loads, display the room server's adv_name (e.g., "Casa_Palms-Room-8c10") in the chat header/title bar.

### 1.6 Room Server Allows Messaging Without Login
**Symptom:** The app allows sending messages to a room server even when NOT logged in. Room servers require login before you can post messages.
**Fix:**
- When a room server contact (type=3) is selected and the user is NOT logged in:
  - Show the message input field as DISABLED/grayed out
  - Display "Login required to send messages" in place of the input placeholder
  - Show a "Login" button prominently
- Only enable the message input AFTER PUSH_CODE_LOGIN_SUCCESS (0x85) is received
- Check login state before sending any message to a room server contact:
```swift
func sendMessage(to contact: Contact, text: String) {
    if contact.type == 3 && !isLoggedIn(to: contact) {
        // Show login prompt instead of sending
        showLoginRequired = true
        return
    }
    // ... proceed with send
}
```
- Also disable the send button visually when not logged in to a room server

### 1.7 Trace Route — Timer Shows But No Output After
**Symptom:** Trace route sends the command, RESP_CODE_SENT is received (device accepted it), 0x88 LogRxData confirms it went over LoRa, but no PUSH_CODE_TRACE_DATA (0x89) comes back. Timer reaches 15s and gets stuck — never clears.
**Debug log analysis:**
```
TX TRACE_PATH [16 bytes]: 24 54 65 ce f7 00 00 00 00 00 45 00 00 00 00 00
RESP_CODE_SENT: expectedACK=4157498708 timeout=7248ms
PUSH 0x88 (LogRxData): confirms packet was transmitted
Then nothing — no 0x89 response ever arrives.
```
**Issues to fix:**
1. **Timeout gets stuck at 15s** — The timeout handler doesn't clear the activity overlay. Same pattern as status request bug. The timeout Task must update @Published properties on MainActor to dismiss the overlay and show a result message.
2. **Check path before sending** — The contact CB2FE6A7 has path_len=0 (direct neighbor). There are no intermediate hops to trace. Before sending CMD_SEND_TRACE_PATH:
   - path_len == 0: Show "This contact is a direct neighbor — no hops to trace." immediately. Don't send.
   - path_len == 0xFF or -1: Show "No known route to this contact." Don't send.
   - path_len > 0: Send trace with ONLY the actual path bytes (no zero padding).
3. **Path data in frame is wrong** — The frame sends `45 00 00 00 00 00` but should only send `path_len` bytes of actual path data, not padded zeros. Only include the real hop hashes from out_path[0..<path_len].
4. **Verify 0x89 parser exists** — Make sure PUSH_CODE_TRACE_DATA (0x89) has an actual parser that handles: reserved(byte), path_len(byte), flags(byte), tag(int32), auth_code(int32), path_hashes(variable), path_snrs(variable).

**Fix ALL timeout handlers across the entire app** — verify every activity indicator properly clears after its timeout period. Check: status request, telemetry, trace route, path info, discover. Each one must dismiss the overlay and show a result/timeout message via MainActor.

### 1.8 Request Telemetry — Timer Works But No Output + Needs Contextual Messaging
**Symptom:** Timer shows and counts up properly but when it expires, nothing happens. Also no guidance for the user about which node types support telemetry.
**Fix:**
1. **Timeout handler stuck** — Same pattern as status/trace. The timeout Task must update @Published on MainActor to dismiss overlay and show timeout message.
2. **Add contextual messaging before sending:**
   - Type 1 (chat companion): "Telemetry is typically only available from sensor nodes. This chat node may not respond."
   - Type 2 (repeater): "Some repeaters support basic telemetry. Waiting for response..."
   - Type 3 (room server): "Room servers don't typically support telemetry."
   - Type 4 (sensor): "Requesting telemetry from sensor..." (normal, expected to work)
3. **On timeout:** Show "No telemetry response — this node may not support telemetry or is out of range."

### 1.9 Show Path — Frame Missing Reserved Byte + Unsupported Fallback
**Symptom:** CMD_GET_ADVERT_PATH sends 33 bytes (code + 32-byte pubkey) but should be 34 bytes (code + reserved + 32-byte pubkey). Returns "Unsupported command."
**Fix:**
1. Fix the frame builder: code(0x2A) + reserved(0x00) + pub_key(32 bytes) = 34 bytes total
2. This command is NOT supported on firmware v1.14.0, so even with the correct frame it will fail
3. When RESP_CODE_ERR is received: fall back to displaying the contact's local out_path data
4. Display: "Direct" for path_len=0, "X hops: [hex hop IDs]" for path_len>0, "No known path" for path_len=0xFF
5. Make sure the fallback result actually appears in the UI — update @Published on MainActor

### 1.10 CRITICAL: ALL Activity Indicator Timeouts Are Stuck
**Symptom:** Multiple features show the activity timer counting up but when the timeout is reached, the overlay gets stuck and never clears. Confirmed on: status request (stuck at 15s), trace route (stuck at 15s), likely affects telemetry and path info too.
**Root Cause:** The timeout Task fires but doesn't update @Published properties on the MainActor, so the UI never dismisses the overlay.
**Fix — GLOBAL — apply to ALL timeout handlers in the entire app:**
```swift
// PATTERN THAT MUST WORK for every timeout:
timeoutTask = Task {
    try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
    if !Task.isCancelled {
        await MainActor.run {
            self.isActivityInProgress = false   // dismiss overlay
            self.activityResult = "Timed out — ..."  // show message
        }
    }
}
```
**Check and fix ALL of these:**
- [ ] Status request timeout (15s)
- [ ] Telemetry request timeout (15s)
- [ ] Trace route timeout (15s)
- [ ] Path info timeout (10s)
- [ ] Discover timeout (30s)
- [ ] Login timeout (suggested_timeout + 3s)
- [ ] CLI command timeout (8s per command)

Also add contextual messaging for status request:
- Type 1 (chat): "Status requests are only supported by repeaters, room servers, and sensors. This node may not respond."
- Type 2/3/4: Normal messaging

### 1.11 CLI Response Routing for Remote Management
**Symptom:** Remote management settings fields sometimes still show placeholders or spinning daisywheels.
**Fix:**
- After sending each CLI command (txt_type=1), wait 500ms then send CMD_SYNC_NEXT_MESSAGE (code 10) to poll for the response
- When receiving a message (code 7 or 16) where txt_type=1 AND sender pubkey matches activeManagementPubkey:
  - Pop the pending CLI command from the queue
  - Strip "> " prefix from response text  
  - Parse value and populate the corresponding settings field
  - Display command + response in CLI terminal section
  - Do NOT show as a chat message
- 8-second timeout per command — show "Timeout" and move to next
- Replace all remaining spinning daisywheels with actual responses or "Timeout"

---

## PRIORITY 2: CHANNEL DISPLAY FIXES

### 2.1 Double Hash Bug
**Symptom:** Channels show "##testing", "##hamradio", "##emergency" with double hash prefix.
**Root Cause:** The channel name stored on the device already includes the "#" (e.g., "#testing"), but the display code adds another "#".
**Fix:** When displaying a channel name, check if it already starts with "#". If yes, display as-is. If no, don't add one.
```swift
// WRONG:
Text("#\(channel.name)")  // produces "##testing"

// RIGHT:
Text(channel.name.hasPrefix("#") ? channel.name : channel.name)
```

### 2.2 Private Channel Incorrectly Shows Hash
**Symptom:** "Casa Palms Channel" displays as "#Casa Palms Channel" with a hash icon, but it's a private channel (no hash in the name on the device).
**Fix:** Only show "#" icon for channels where the name actually starts with "#". For channels where the name does NOT start with "#" and index > 0, use a lock icon and display the name without any prefix.

### 2.3 Icon Assignment Logic
**Symptom:** #florida shows megaphone icon (should be # icon). Some hashtag channels show # icon, others show megaphone.
**Fix:** Correct icon logic:
```swift
func iconForChannel(_ channel: MeshChannel) -> String {
    if channel.index == 0 {
        return "megaphone.fill"  // Public channel ONLY
    } else if channel.name.hasPrefix("#") {
        return "number"  // Hashtag channels
    } else {
        return "lock.fill"  // Private channels
    }
}
```

### 2.4 Public Channel Placement
**Current:** Public Channel appears above the "Channels" section header.
**Fix:** Move Public Channel inside the "Channels" section as the first item, OR keep it separate but make it visually consistent with the channel section styling.

### 2.5 Channel Messaging with Correct Index
**Bug:** CMD_SEND_CHANNEL_TXT_MSG may be hardcoded to channel_idx=0.
**Fix:** When sending a message from a channel chat, use that channel's actual index:
```swift
func sendChannelMessage(text: String, channel: MeshChannel) {
    // Use channel.index, NOT hardcoded 0
    buildChannelMessageFrame(txt_type: 0, channel_idx: UInt8(channel.index), timestamp: currentEpoch, text: text)
}
```

---

## PRIORITY 3: TOOLBAR ICON BEHAVIOR

### 3.1 Clarify Toolbar Icon Functions
The toolbar has multiple icons that need clear, distinct purposes:
- **Signal/Broadcast icon ((•))**: Should send a self-advertisement (CMD_SEND_SELF_ADVERT code 7). Show brief "Advertisement sent" confirmation. Should NEVER disconnect.
- **Discover icon (if present)**: Open the Discover sheet to scan for nearby nodes.
- **Settings gear icon**: Open local device settings.
- **Remote management icon (wrench)**: Only visible when logged into a remote device. Opens remote management.

### 3.2 Add Tooltips
On macOS, add tooltips to all toolbar icons so users know what each does on hover:
- "(•)" → "Send Advertisement"
- Discover → "Discover Nearby Nodes"  
- Gear → "Device Settings"
- Wrench → "Remote Management"

---

## PRIORITY 4: DISCOVER FEATURE

### 4.1 Discover Command Not Supported on This Firmware
**Status:** CMD_SEND_CONTROL_DATA (0x37/55) returns "Unsupported command" on firmware v1.14.0 (FIRMWARE_VER_CODE=10) even with the corrected 3-byte frame `37 00 80`. This has been tested multiple times with different frame formats — the command is genuinely not supported on this firmware version for BLE Companion radios.

**Fix — Graceful degradation:**
- When the app sends CMD_SEND_CONTROL_DATA and receives RESP_CODE_ERR with err_code=1 (Unsupported command), do NOT show a raw error to the user
- Instead show: "Discover is not available on this firmware version. Try sending an advertisement to find nearby nodes."
- Disable/hide the Discover button if the firmware version doesn't support it. After the first failed attempt, remember this and don't offer the option again for this device session.
- **Alternative discover approach:** Instead of CMD_SEND_CONTROL_DATA, offer "Send Flood Advertisement" as an alternative way to discover nearby nodes. This sends CMD_SEND_SELF_ADVERT (code 7, param byte 1 for flood mode) and then waits for PUSH_CODE_ADVERT (0x80) responses as nearby nodes respond with their own advertisements. This IS supported on all firmware versions.
- Implement this fallback flow:
  1. User taps "Discover" 
  2. App tries CMD_SEND_CONTROL_DATA first
  3. If unsupported: automatically fall back to flood advertisement
  4. Send CMD_SEND_SELF_ADVERT with flood=1
  5. Listen for PUSH_CODE_ADVERT (0x80) and PUSH_CODE_NEW_ADVERT (0x8A) for 30 seconds
  6. Display any discovered nodes in the discover list
  7. Show message: "Using advertisement-based discovery (firmware does not support active discover scan)"

---

## PRIORITY 5: PUSH NOTIFICATION HANDLERS

### Already Handled ✅
- 0x82 PUSH_CODE_SEND_CONFIRMED
- 0x83 PUSH_CODE_MSG_WAITING  
- 0x85 PUSH_CODE_LOGIN_SUCCESS
- 0x86 PUSH_CODE_LOGIN_FAIL
- 0x88 PUSH_CODE_LOG_RX_DATA (identified, log+ignore)

### Implement These:

**0x80 — PUSH_CODE_ADVERT** (High priority)
Known contact sent advertisement. Payload: 32-byte public key.
Action: Trigger incremental contact sync — send CMD_GET_CONTACTS with 'since' = lastContactSyncMod.

**0x81 — PUSH_CODE_PATH_UPDATED** (High priority)
Contact path changed. Payload: 32-byte public key.
Action: Trigger incremental contact sync with 'since' param.

**0x84 — PUSH_CODE_RAW_DATA**
Raw LoRa packet received.
Frame: code(0x84), SNR*4(int8), RSSI(int8), reserved(0xFF), payload(remainder).
Action: Log at debug level. Optional: show in advanced packet log view.

**0x87 — PUSH_CODE_STATUS_RESPONSE**
Repeater/sensor status response.
Frame: code(0x87), reserved(0), pub_key_prefix(6 bytes), status_data(remainder).
Action: Display in repeater management view when a status request was pending.

**0x89 — PUSH_CODE_TRACE_DATA**
Trace route result.
Frame: code(0x89), reserved(0), path_len(byte), flags(0), tag(int32), auth_code(int32), path_hashes(path_len bytes), path_snrs(path_len+1 bytes, each = SNR*4).
Action: Display visual trace route.

**0x8A — PUSH_CODE_NEW_ADVERT**
New contact discovered (when manual_add_contacts=1). Same format as RESP_CODE_CONTACT.
Action: Show in "Pending Contacts" section for user to accept/reject.

**0x8B — PUSH_CODE_TELEMETRY_RESPONSE**
Telemetry from sensor node.
Frame: code(0x8B), reserved(0), pub_key_prefix(6 bytes), LPP_sensor_data(remainder).
Action: Parse Cayenne LPP data, display sensor values.

**0x8C — PUSH_CODE_BINARY_RESPONSE**
Binary request response.
Frame: code(0x8C), reserved(0), tag(uint32), response_data(remainder).
Action: Match tag to pending request, process response.

**0x8D — PUSH_CODE_PATH_DISCOVERY_RESPONSE**
Path discovery result.
Action: Display path information for contact.

**0x8E — PUSH_CODE_CONTROL_DATA**
Control packet (discover responses).
Frame: code(0x8E), SNR*4(int8), RSSI(int8), path_len(byte), path(variable), payload(remainder).
Action: Parse and display in discover view.

**0x8F — PUSH_CODE_CONTACT_DELETED**
Contact evicted from device (storage full, new contact added).
Action: Show notification "Contact [name] was removed to make room for new contacts." Remove from local contacts list.

**0x90 — PUSH_CODE_CONTACTS_FULL**
Contact storage completely full.
Action: Show warning "Contact storage full ([max] contacts). New contacts cannot be added."

---

## PRIORITY 6: REMAINING PROTOCOL COMMANDS

### 6.1 Channel Operations (mostly done, verify)
- CMD_GET_CHANNEL (0x1F/31): Send index, receive RESP_CODE_CHANNEL_INFO (0x12/18)
- CMD_SET_CHANNEL (0x20/32): Set index + name(32 bytes) + secret(32 bytes)
- Create/Join channel UI with proper hashtag vs private handling

### 6.2 Status Request
CMD_SEND_STATUS_REQ (0x1B/27): code + pub_key(32 bytes)
Response via PUSH_CODE_STATUS_RESPONSE (0x87)
Add "Request Status" button on repeater/sensor contacts.

### 6.3 Telemetry Request  
CMD_SEND_TELEMETRY_REQ (0x27/39): code + reserved(3 zeros) + pub_key(32 bytes)
Response via PUSH_CODE_TELEMETRY_RESPONSE (0x8B)
Add "Request Telemetry" button on sensor contacts (type=4).

### 6.4 Trace Route
CMD_SEND_TRACE_PATH (0x24/36): code + tag(int32) + auth_code(int32) + flags(0) + path(hashes)
Response via PUSH_CODE_TRACE_DATA (0x89)
Add "Trace Route" in contact context menu.

### 6.5 Advert Path Query
CMD_GET_ADVERT_PATH (0x2A/42): code + reserved(0) + pub_key(32 bytes)
Response: RESP_CODE_ADVERT_PATH (0x16/22): recv_timestamp(uint32) + path_len(byte) + path(bytes)
Show "Last Known Path" in contact detail.

### 6.6 Auto-Add Configuration
CMD_SET_AUTOADD_CONFIG (0x3A/58): code + bitmask(byte)
Response: RESP_CODE_AUTOADD_CONFIG (0x19/25)
Add to device settings under Privacy & Security.

### 6.7 Allowed Repeat Frequencies
CMD_GET_ALLOWED_REPEAT_FREQ (0x3C/60): code only
Response: RESP_ALLOWED_REPEAT_FREQ (0x1A/26): array of {lower(uint32), upper(uint32)}
Show in radio settings when repeat mode enabled.

### 6.8 Signed Messages
Handle TXT_TYPE_SIGNED_PLAIN (value 2) — show "Verified ✓" badge on received signed messages.

---

## PRIORITY 7: UI/UX POLISH

### 7.1 Remote Management
- [ ] Lazy-load admin settings — fetch only "ver"+"clock" on login, rest when admin menu opened
- [ ] Toggle buttons: bright teal = active, dimmed gray = inactive for all on/off options
- [ ] Distinct toolbar icons: gearshape = local, wrench.and.screwdriver = remote
- [ ] Clock sync warning if >24h off
- [ ] Permission-based UI (Guest/Read-only/Read-write/Admin)
- [ ] Session timeout detection

### 7.2 Battery
- [ ] Chemistry picker: LiPo/NMC, LiFePO4, Li-Ion 18650
- [ ] Proper voltage-to-percentage curves per chemistry
- [ ] ADC multiplier for remote devices

### 7.4 Activity Indicators for All Wait Operations
**Symptom:** When the app sends a command that takes time (trace route, telemetry, discover, login, CLI commands, status request), there's no visible indicator that anything is happening. The user doesn't know if it's working or broken.
**Fix:** Every operation that involves waiting for a response over BLE or LoRa must show an activity indicator:

**Implementation — create a reusable ActivityOverlay component:**
```swift
struct ActivityOverlay: View {
    let message: String
    let timeout: TimeInterval
    @State private var elapsed: TimeInterval = 0
    
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
            // Show elapsed time so user knows it's still working
            Text("\(Int(elapsed))s / \(Int(timeout))s")
                .font(.caption)
                .foregroundColor(.tertiary)
        }
    }
}
```

**Apply to ALL of these operations:**
- **Login:** "Logging in to [device name]..." with timeout countdown
- **Trace Route:** "Tracing route to [contact]..." with 15s timeout bar
- **Telemetry Request:** "Requesting telemetry from [contact]..." with 15s timeout
- **Status Request:** "Requesting status from [device]..." with timeout
- **Discover Scan:** "Scanning for nearby nodes..." with 30s countdown
- **CLI Commands:** "Sending command: [cmd]..." with 8s timeout per command
- **Settings Fetch:** "Loading remote settings... (5/22)" with progress count
- **Contact Sync:** "Syncing contacts... 2/3" with count
- **Channel Sync:** "Syncing channels... 15/40" with count
- **Message Send:** Already shows sending/sent/delivered states — this is good
- **Advertisement:** "Sending advertisement..." with brief confirmation

**Rules:**
- Show a spinner/progress indicator immediately when the operation starts
- Show what operation is happening in text
- Show elapsed time or progress count where applicable
- When the operation completes (success or timeout), replace the indicator with the result
- Timeout should show a clear message: "Timed out — [specific guidance]"
- Never leave the user staring at a blank screen wondering if something happened

### 7.6 Tooltips, Help Text & User Guidance
**Goal:** Make every button, icon, and feature self-explanatory so new users never wonder "what does this do?"

**Tooltips on all toolbar and action icons (macOS hover, iOS long-press):**
- Broadcast/signal icon ((•)): "Send Advertisement — announce your presence on the mesh"
- Discover icon: "Discover — find nearby mesh nodes"
- Local settings gear: "Device Settings — configure your local radio"
- Remote management wrench: "Remote Management — configure [device name]"
- Disconnect button: "Disconnect from [device name]"
- Refresh button: "Refresh — re-sync contacts and settings from device"

**Tooltips on contact actions (context menu items):**
- Send Message: "Send a direct encrypted message"
- Trace Route: "Trace the path your messages take through the mesh"
- Show Path: "Show the current routing path to this contact"
- Request Status: "Request operational status (repeaters/sensors only)"
- Request Telemetry: "Request sensor readings (sensor nodes only)"
- Share on Mesh: "Share this contact's info with nearby nodes"
- Export Link: "Copy a meshcore:// link to share this contact"
- Reset Path: "Clear the cached route — next message will discover a new path"
- Remove Contact: "Remove this contact from your device"

**Section footer help text in Settings:**
- Radio Configuration: "⚠️ Changing radio parameters will disconnect you from nodes using different settings. All nodes must use the same frequency, bandwidth, SF, and CR to communicate."
- Privacy & Security: "Controls what information your device shares on the mesh network."
- Tuning Parameters: "Advanced — adjust timing parameters for mesh performance. Default values work well for most setups."
- Danger Zone: "⚠️ These actions cannot be undone."

**Contextual help for complex features:**
- Channel creation: "Hashtag channels (#name) — anyone who knows the name can join. Private channels — require a shared secret key."
- Room server chat: "Room servers store messages. When you login, you'll receive up to 32 recent messages."
- Repeater management: "You are remotely managing this device over LoRa. Commands may take a few seconds to travel through the mesh."
- Battery chemistry picker: "Select the battery type in your device for accurate percentage calculation."

**First-launch onboarding (future):**
- Brief walkthrough: "Welcome to MeshCore" → "Turn on your radio" → "Connect via Bluetooth" → "Send your first message"
- Could be a simple 3-4 screen onboarding flow

**Implementation on macOS:**
```swift
Button(action: { sendAdvertisement() }) {
    Image(systemName: "antenna.radiowaves.left.and.right")
}
.help("Send Advertisement — announce your presence on the mesh")
```

**Implementation on iOS (accessibility + long-press):**
```swift
Button(action: { sendAdvertisement() }) {
    Image(systemName: "antenna.radiowaves.left.and.right")
}
.accessibilityLabel("Send Advertisement")
.accessibilityHint("Announce your presence on the mesh network")
```

### 7.8 Local User Data & Personalization
**Goal:** Store user-facing enhancements locally in the app to make the experience personal and friendly, separate from the mesh protocol data on the radio.

**What the RADIO stores (source of truth for mesh):**
- Contacts (public keys, adv_names, paths, flags)
- Channels (names, secrets)
- Radio config, identity, encryption keys

**What the APP should store locally (UserDefaults, SwiftData, or JSON):**

1. **Custom nicknames/aliases for contacts:**
   - User can rename "CB2FE6A7" to "Dad's Radio" or "Mike's T-Deck"
   - Show the custom name in the sidebar and chat, with the original adv_name in smaller text underneath
   - Store as a dictionary: [publicKeyHex: customName]
   - Add "Rename" option in contact context menu
   - Long-press or right-click contact → "Set Nickname..."

2. **Contact notes:**
   - Free-text notes per contact: "Repeater on the water tower, solar powered"
   - Show in contact detail view
   - Useful for remembering what infrastructure devices are and where they are

3. **Per-contact notification preferences:**
   - Mute specific contacts or channels
   - Custom notification sound per contact (future)

4. **Last known device state:**
   - Cache the last device info, contacts, channels, and settings
   - When app launches before connecting, show the cached data grayed out with "Last seen: X ago"
   - This makes the app feel instant instead of blank until BLE connects

5. **Favorites / pinned contacts:**
   - Pin important contacts to the top of the sidebar
   - The MeshCore protocol supports flags bit 0 = favourite — sync this to the device via CMD_ADD_UPDATE_CONTACT with the favourite flag set

6. **Message drafts:**
   - Save unsent message text per contact so it survives app restarts
   - If user was typing a message and backgrounds the app, the draft is preserved

7. **Color/emoji tags for contacts:**
   - Assign colors or emoji to contacts for visual organization
   - e.g., red tag for emergency contacts, blue for family, green for infrastructure

8. **Custom channel ordering:**
   - Drag to reorder channels in the sidebar
   - Store order locally — doesn't affect the device channel slots

9. **Recently used contacts:**
   - Track which contacts you message most frequently
   - Option to sort by "Most Recent" or "Most Frequent" in addition to alphabetical

10. **App preferences:**
    - Theme preference (follow system / always dark / always light)
    - Default message send behavior (enter to send vs button)
    - Sound/vibration preferences
    - Map tile provider preference (when map view is added)
    - Battery chemistry selection (LiPo, LiFePO4, Li-Ion)
    - Remember last connected device for auto-connect

**Implementation:** Use SwiftData with a LocalUserData model, or simple JSON files in the app's Documents directory (similar to current message storage). Key the data by device public key so settings persist per-radio.

### 7.9 General UI
- [ ] Empty states: no connection, no contacts, no messages
- [ ] Pull-to-refresh in contact list and chat
- [ ] Keyboard: chat input above keyboard, dismiss on scroll, send on Return
- [ ] All list rows tappable: .contentShape(Rectangle()) + Spacer()
- [ ] Message character count (max 160 for DM)
- [ ] Haptic feedback on message send (iOS)

---

## PRIORITY 8: iOS DEPLOYMENT & BACKGROUND BLE

### 8.1 Pre-deployment Verification
- [ ] ios/Info.plist: UIBackgroundModes with bluetooth-central
- [ ] ios/Info.plist: NSBluetoothAlwaysUsageDescription
- [ ] CBCentralManager with CBCentralManagerOptionRestoreIdentifierKey
- [ ] willRestoreState delegate: re-subscribe to NUS TX characteristic
- [ ] Auto-reconnect on disconnect: central.connect() in didDisconnectPeripheral
- [ ] Local notifications via UNUserNotificationCenter for background messages
- [ ] Request notification permission on first launch
- [ ] NavigationSplitView works on iPhone (compact = stack)
- [ ] Clean build: xcodebuild -scheme MeshCoreApple -destination 'generic/platform=iOS' build

### 8.2 iPhone Test Procedure
1. Connect iPhone via USB, enable Developer Mode
2. Xcode: Signing & Capabilities → Automatically manage signing → Personal Team  
3. Bundle ID: com.mbedworth.meshcore
4. Cmd+R to build and deploy
5. Trust cert: Settings → General → VPN & Device Management
6. Connect to Mesh Pocket, send message, verify delivery
7. Background app, wait 20+ minutes
8. Receive mesh message → verify notification + connection alive

---

## PRIORITY 9: TESTFLIGHT PREPARATION

### 9.1 Apple Developer Program
- [ ] Enroll in Apple Developer Program ($99/year) at developer.apple.com
- [ ] Create App ID: com.mbedworth.meshcore
- [ ] Create provisioning profiles for iOS, macOS, watchOS

### 9.2 App Store Connect Setup
- [ ] Create app record in App Store Connect
- [ ] App name: "MeshCore" (or "MeshCore Apple" if taken)
- [ ] Bundle ID: com.mbedworth.meshcore
- [ ] Primary language: English
- [ ] Category: Utilities or Social Networking

### 9.3 TestFlight Build
- [ ] Archive the app in Xcode: Product → Archive
- [ ] Upload to App Store Connect via Xcode Organizer
- [ ] Add beta testers (email addresses)
- [ ] Submit for Beta App Review (first build requires review)
- [ ] Testers receive TestFlight invite via email

### 9.4 Required for TestFlight
- [ ] App icon (1024x1024) — already have this
- [ ] Privacy policy URL — create a simple one hosted on GitHub Pages or similar
- [ ] App description
- [ ] "What to Test" notes for beta testers
- [ ] Export compliance: No encryption? Mark as "No" (MeshCore uses encryption but it's in the firmware, not the app)

### 9.5 Required for App Store (later)
- [ ] Screenshots for iPhone 6.5" and 5.5" displays
- [ ] Screenshots for iPad 12.9"
- [ ] App Store description (max 4000 chars)
- [ ] Keywords
- [ ] Support URL
- [ ] Marketing URL (optional)

---

## PRIORITY 10: LOCAL DATA & USER EXPERIENCE LAYER

### 10.1 Local Database for App-Side Data
**Goal:** Store user-customized data that lives in the app, not on the radio. The radio stores mesh network data. The app stores the human experience layer on top of it.

**Use SwiftData (or Core Data) to persist:**

**Custom Contact Nicknames:**
- Let users rename any contact with a friendly name (e.g., "CB2FE6A7" → "Dad's Radio")
- Display the nickname in the sidebar, chat header, and everywhere the contact appears
- Show the original adv_name in smaller text underneath or in contact details
- Nickname is app-local only — doesn't change anything on the radio
- Sync across devices via iCloud if user wants

**Full Message History:**
- The radio only queues ~256 messages and they're volatile. The app should store ALL messages permanently
- Already storing in JSON files — consider migrating to SwiftData for better performance and querying
- Include: message text, timestamp, sender, delivery status, SNR, round trip time

**Contact Notes:**
- Free-text notes field on each contact (e.g., "Repeater on top of water tower, solar powered")
- Useful for remembering what devices are and where they are

**Favorite/Pinned Contacts:**
- Pin important contacts to the top of the sidebar list
- Star/heart icon toggle
- Persist locally

**Last Known Device State Cache:**
- Cache the last known: battery level, firmware version, radio params, statistics, last connected timestamp
- Show this cached data in the UI immediately on launch, before BLE connects
- Gray it out with "Last known — connecting..." until fresh data arrives
- This makes the app feel instant instead of showing empty fields until BLE syncs

**Saved Login Credentials:**
- Remember room server and repeater passwords in Apple Keychain (not UserDefaults)
- "Remember Password" toggle on login screen
- Auto-fill on next login attempt
- Keychain is encrypted and protected by device passcode/biometrics

**Channel Secrets:**
- The device never returns channel secrets. Store them locally when the user creates or joins a channel
- Map channel_idx → secret in the local database
- Needed for: creating new channels, re-joining after device reset, sharing channels with others

**Contact Groups:**
- Let users create custom groups: "Family", "Local Mesh", "Emergency", "Ham Radio Buddies"
- Drag contacts into groups
- Display as collapsible sections in the sidebar
- A contact can be in multiple groups

**Per-Contact Notification Preferences:**
- Mute specific contacts or channels
- Custom notification sounds per contact (later)
- "Do Not Disturb" per contact

**Search:**
- Search contacts by name, nickname, or public key prefix
- Search message history by text content
- Search channels by name

### 10.2 UI Polish for Nicknames
```swift
// Contact row in sidebar:
VStack(alignment: .leading) {
    Text(contact.nickname ?? contact.name)  // show nickname if set
        .font(.headline)
    if let nickname = contact.nickname {
        Text(contact.name)  // show original name underneath
            .font(.caption)
            .foregroundColor(.secondary)
    }
    Text("direct • 3 min ago")
        .font(.caption2)
        .foregroundColor(.tertiary)
}

// Set nickname: long-press or right-click → "Set Nickname..."
// Edit in contact detail view
```

---

## PRIORITY 11: FUTURE FEATURES

- [ ] Map view with MapKit — plot contacts/repeaters/rooms from lat/lon
- [ ] Offline map tile caching
- [ ] watchOS app — messaging + complications + background BLE
- [ ] Internet map integration (meshcore.dev/map)
- [ ] Contact sharing via QR code / AirDrop
- [ ] OTA firmware update
- [ ] Keychain for credentials/secrets
- [ ] Face ID / Touch ID lock
- [ ] Encrypted local database
- [ ] Widget for home screen (connection status, last message)

---

## REFERENCE: COMPLETE COMMAND CODE TABLE

| Dec | Hex | Name | Status |
|-----|------|------|--------|
| 1 | 0x01 | CMD_APP_START | ✅ |
| 2 | 0x02 | CMD_SEND_TXT_MSG | ✅ |
| 3 | 0x03 | CMD_SEND_CHANNEL_TXT_MSG | ⚠️ needs channel_idx fix |
| 4 | 0x04 | CMD_GET_CONTACTS | ✅ (needs atomic swap) |
| 5 | 0x05 | CMD_GET_DEVICE_TIME | ✅ |
| 6 | 0x06 | CMD_SET_DEVICE_TIME | ✅ |
| 7 | 0x07 | CMD_SEND_SELF_ADVERT | ✅ |
| 8 | 0x08 | CMD_SET_ADVERT_NAME | ✅ |
| 9 | 0x09 | CMD_ADD_UPDATE_CONTACT | ✅ |
| 10 | 0x0A | CMD_SYNC_NEXT_MESSAGE | ✅ |
| 11 | 0x0B | CMD_SET_RADIO_PARAMS | ✅ |
| 12 | 0x0C | CMD_SET_RADIO_TX_POWER | ✅ |
| 13 | 0x0D | CMD_RESET_PATH | ✅ |
| 14 | 0x0E | CMD_SET_ADVERT_LATLON | ✅ |
| 15 | 0x0F | CMD_REMOVE_CONTACT | ✅ |
| 16 | 0x10 | CMD_SHARE_CONTACT | ✅ |
| 17 | 0x11 | CMD_EXPORT_CONTACT | ✅ |
| 18 | 0x12 | CMD_IMPORT_CONTACT | ✅ |
| 19 | 0x13 | CMD_REBOOT | ✅ |
| 20 | 0x14 | CMD_GET_BATT_AND_STORAGE | ✅ |
| 21 | 0x15 | CMD_SET_TUNING_PARAMS | ✅ |
| 22 | 0x16 | CMD_DEVICE_QUERY | ✅ |
| 25 | 0x19 | CMD_SEND_RAW_DATA | ❌ |
| 26 | 0x1A | CMD_SEND_LOGIN | ✅ |
| 27 | 0x1B | CMD_SEND_STATUS_REQ | ❌ needs UI |
| 31 | 0x1F | CMD_GET_CHANNEL | ✅ (display bugs) |
| 32 | 0x20 | CMD_SET_CHANNEL | ❌ |
| 36 | 0x24 | CMD_SEND_TRACE_PATH | ❌ |
| 37 | 0x25 | CMD_SET_DEVICE_PIN | ✅ |
| 38 | 0x26 | CMD_SET_OTHER_PARAMS | ✅ |
| 39 | 0x27 | CMD_SEND_TELEMETRY_REQ | ❌ |
| 40 | 0x28 | CMD_GET_CUSTOM_VARS | ✅ |
| 41 | 0x29 | CMD_SET_CUSTOM_VAR | ✅ |
| 42 | 0x2A | CMD_GET_ADVERT_PATH | ❌ |
| 43 | 0x2B | CMD_GET_TUNING_PARAMS | ✅ |
| 50 | 0x32 | CMD_SEND_BINARY_REQ | ❌ |
| 51 | 0x33 | CMD_FACTORY_RESET | ✅ |
| 55 | 0x37 | CMD_SEND_CONTROL_DATA | ⚠️ may not be supported on this FW |
| 56 | 0x38 | CMD_GET_STATS | ✅ |
| 58 | 0x3A | CMD_SET_AUTOADD_CONFIG | ❌ |
| 60 | 0x3C | CMD_GET_ALLOWED_REPEAT_FREQ | ❌ |

## REFERENCE: COMPLETE RESPONSE/PUSH CODE TABLE

| Dec | Hex | Name | Status |
|-----|------|------|--------|
| 0 | 0x00 | RESP_CODE_OK | ✅ |
| 1 | 0x01 | RESP_CODE_ERR | ✅ |
| 2 | 0x02 | RESP_CODE_CONTACTS_START | ✅ |
| 3 | 0x03 | RESP_CODE_CONTACT | ✅ |
| 4 | 0x04 | RESP_CODE_END_OF_CONTACTS | ✅ |
| 5 | 0x05 | RESP_CODE_SELF_INFO | ✅ |
| 6 | 0x06 | RESP_CODE_SENT | ✅ |
| 7 | 0x07 | RESP_CODE_CONTACT_MSG_RECV | ✅ |
| 8 | 0x08 | RESP_CODE_CHANNEL_MSG_RECV | ✅ |
| 9 | 0x09 | RESP_CODE_CURR_TIME | ✅ |
| 10 | 0x0A | RESP_CODE_NO_MORE_MESSAGES | ✅ |
| 11 | 0x0B | RESP_CODE_EXPORT_CONTACT | ✅ |
| 12 | 0x0C | RESP_CODE_BATT_AND_STORAGE | ✅ |
| 13 | 0x0D | RESP_CODE_DEVICE_INFO | ✅ |
| 14 | 0x0E | RESP_CODE_PRIVATE_KEY | ❌ |
| 15 | 0x0F | RESP_CODE_DISABLED | ❌ |
| 16 | 0x10 | RESP_CODE_CONTACT_MSG_RECV_V3 | ✅ |
| 17 | 0x11 | RESP_CODE_CHANNEL_MSG_RECV_V3 | ✅ |
| 18 | 0x12 | RESP_CODE_CHANNEL_INFO | ✅ (display bugs) |
| 19 | 0x13 | RESP_CODE_SIGN_START | ❌ |
| 20 | 0x14 | RESP_CODE_SIGNATURE | ❌ |
| 21 | 0x15 | RESP_CODE_CUSTOM_VARS | ✅ |
| 22 | 0x16 | RESP_CODE_ADVERT_PATH | ❌ |
| 23 | 0x17 | RESP_CODE_TUNING_PARAMS | ✅ |
| 24 | 0x18 | RESP_CODE_STATS | ✅ |
| 25 | 0x19 | RESP_CODE_AUTOADD_CONFIG | ❌ |
| 26 | 0x1A | RESP_ALLOWED_REPEAT_FREQ | ❌ |
| 128 | 0x80 | PUSH_CODE_ADVERT | ❌ High priority |
| 129 | 0x81 | PUSH_CODE_PATH_UPDATED | ❌ High priority |
| 130 | 0x82 | PUSH_CODE_SEND_CONFIRMED | ✅ |
| 131 | 0x83 | PUSH_CODE_MSG_WAITING | ✅ |
| 132 | 0x84 | PUSH_CODE_RAW_DATA | ❌ |
| 133 | 0x85 | PUSH_CODE_LOGIN_SUCCESS | ✅ |
| 134 | 0x86 | PUSH_CODE_LOGIN_FAIL | ✅ |
| 135 | 0x87 | PUSH_CODE_STATUS_RESPONSE | ❌ |
| 136 | 0x88 | PUSH_CODE_LOG_RX_DATA | ✅ log+ignore |
| 137 | 0x89 | PUSH_CODE_TRACE_DATA | ❌ |
| 138 | 0x8A | PUSH_CODE_NEW_ADVERT | ❌ |
| 139 | 0x8B | PUSH_CODE_TELEMETRY_RESPONSE | ❌ |
| 140 | 0x8C | PUSH_CODE_BINARY_RESPONSE | ❌ |
| 141 | 0x8D | PUSH_CODE_PATH_DISCOVERY_RESPONSE | ❌ |
| 142 | 0x8E | PUSH_CODE_CONTROL_DATA | ❌ |
| 143 | 0x8F | PUSH_CODE_CONTACT_DELETED | ❌ |
| 144 | 0x90 | PUSH_CODE_CONTACTS_FULL | ❌ |
