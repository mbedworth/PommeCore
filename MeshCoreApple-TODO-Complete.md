# MeshCoreApple — Complete Development TODO
## Comprehensive Task List for Claude Code Sessions

**Project:** ~/Developer/MeshCoreApple
**Git:** Private repo on GitHub (git push after each major task)
**Last Updated:** March 14, 2026

---

## PRIORITY 1: BLOCKING BUGS

### 1.1 Disconnect Does Not Work Properly
**Symptom:** After disconnecting, rescanning fails to find the device.
**Root Cause:** The BLE connection isn't being cleanly terminated.
**Fix:**
- When user taps Disconnect, call `centralManager.cancelPeripheralConnection(peripheral)` on the CBPeripheral
- Clear all local state: `connectedPeripheral = nil`, NUS TX/RX characteristics = nil
- Clear the connection state machine
- Wait for `centralManager(_:didDisconnectPeripheral:error:)` delegate callback to confirm
- Only then reset UI to "Disconnected" state
- The device should be re-discoverable immediately — test by scanning within 2 seconds of disconnect
- Also handle unexpected disconnects (error != nil) with auto-reconnect attempt

### 1.2 Contacts Disappear During Admin Fetch
**Symptom:** When CLI responses come in from a remote device, the sidebar contact list goes empty.
**Root Cause:** CLI response handling or CMD_SYNC_NEXT_MESSAGE polling triggers a contact re-sync that clears the displayed array.
**Fix:**
```swift
// Use atomic swap pattern — NEVER clear displayed contacts mid-sync
private var pendingContacts: [Contact] = []

func handleContactsStart(count: Int) {
    pendingContacts = []  // clear BUFFER only
}

func handleContact(contact: Contact) {
    pendingContacts.append(contact)
}

func handleEndOfContacts(lastmod: UInt32) {
    DispatchQueue.main.async {
        self.contacts = self.pendingContacts  // atomic swap
        self.pendingContacts = []
        self.lastContactSyncMod = lastmod
    }
}
```
- Only trigger CMD_GET_CONTACTS from: initial connection, PUSH_CODE_ADVERT (0x80), PUSH_CODE_PATH_UPDATED (0x81), or manual refresh
- NEVER trigger contact re-sync from CLI response handling or message sync

### 1.3 CLI Response Routing for Remote Management
**Symptom:** Remote management settings show placeholders/"value" or spinning daisywheels instead of actual device values.
**Root Cause:** CLI responses arrive as code 7 (RESP_CODE_CONTACT_MSG_RECV) messages with txt_type=1 from the managed device, but aren't being captured and routed to the settings UI.
**Fix:**
- After sending each CLI command (txt_type=1), wait 500ms then send CMD_SYNC_NEXT_MESSAGE (code 10) to poll for the response
- When receiving a message (code 7 or 16) where txt_type=1 AND sender pubkey matches activeManagementPubkey:
  - Pop the pending CLI command from the queue
  - Strip the "> " prefix from the response text
  - Parse the value and populate the corresponding settings field
  - Display in the CLI terminal section
  - Do NOT display as a chat message
- Add 8-second timeout per CLI command — if no response, show "Timeout" and move to next command
- Replace all spinning daisywheels with actual response text or "Timeout"

### 1.4 Compiler Warnings
**Fix these warnings:**
1. **3x "Main actor-isolated static property 'logger' can not be referenced from a Sendable closure"** in MeshCoreViewModel.swift — Fix: mark the logger as `nonisolated(unsafe) static let logger = Logger(...)` or create a local reference before the closure
2. **"The app icon set 'AppIcon' has an unassigned child"** in Assets.xcassets — Fix: ensure macOS AppIcon.appiconset/Contents.json properly maps the PNG files. For single-icon mode in Xcode 15+, the Contents.json needs proper platform entries for both iOS and macOS

---

## PRIORITY 2: CHANNEL SYNC (Critical Missing Feature)

### 2.1 Channel Fetch Command
**Exact command code: CMD_GET_CHANNEL = 0x1F (31 decimal)**

Frame structure:
```
CMD_GET_CHANNEL {
  code: byte    // 0x1F (31)
  channel_idx: byte   // 0 to max_channels-1
}
```

Response: RESP_CODE_CHANNEL_INFO (code 0x12 / 18 decimal):
```
RESP_CODE_CHANNEL_INFO {
  code: byte         // 0x12 (18)
  channel_idx: byte  // 0-39
  channel_name: chars(32)  // null-terminated, null-padded
  flags: byte        // reserved
  reserved: bytes    // remainder
}
```
**Important:** The channel SECRET is NEVER returned by the device. Clients must store secrets locally.

### 2.2 Channel Sync Flow
After contact sync completes (RESP_CODE_END_OF_CONTACTS), iterate through channels:
```swift
func syncChannels() {
    let maxChannels = deviceInfo.maxChannels  // from RESP_CODE_DEVICE_INFO byte 3 (our device: 40)
    for idx in 0..<maxChannels {
        sendGetChannel(index: UInt8(idx))
        // Small delay between requests to avoid overwhelming the radio
    }
}

func sendGetChannel(index: UInt8) {
    var frame = Data([0x1F, index])
    sendFrame(frame)
}
```
- Parse each RESP_CODE_CHANNEL_INFO response
- If channel_name is empty/all-zeros, the slot is unused — skip it
- If channel_name has content, it's a configured channel
- Show sync progress: "Syncing channels 0/40..."

### 2.3 Channel Types & Display
- **Index 0** = Public Channel (well-known PSK). Secret = base64 decode of "izOH6cXN6mrJ5e26oRXNcg==" → hex bytes: `8b 33 87 e9 c5 cd ea 6a c9 e5 ed ba a1 15 cd 72`
- **Names starting with "#"** = Hashtag channels (secret derived from channel name by hashing)
- **Other names** = Private channels (user-provided secret, stored locally)

Display in sidebar ABOVE contacts:
- Public Channel: megaphone icon, always shown
- #hashtag channels: "#" icon
- Private channels: lock icon

### 2.4 Channel Create/Join
CMD_SET_CHANNEL (code 0x20 / 32 decimal):
```
CMD_SET_CHANNEL {
  code: byte         // 0x20 (32)
  channel_idx: byte  // 0-39
  channel_name: chars(32)  // null-padded
  secret: bytes(32)  // the shared encryption key
}
```

UI options:
- "Join Hashtag Channel" — user enters "#name", app derives secret from name
- "Create Private Channel" — user enters name, app generates random 32-byte secret
- "Join Private Channel" — user enters name + pastes hex secret
- "Remove Channel" — send CMD_SET_CHANNEL with empty name to clear the slot

### 2.5 Channel Messaging
Already have CMD_SEND_CHANNEL_TXT_MSG (code 3) — need to pass the correct channel_idx (not just 0 for public):
```
CMD_SEND_CHANNEL_TXT_MSG {
  code: byte = 3
  txt_type: byte = 0
  channel_idx: byte   // <-- use the actual channel index, not hardcoded 0
  sender_timestamp: uint32
  text: varchar
}
```

---

## PRIORITY 3: DISCOVER / NODE DISCOVERY

### 3.1 Fix Discover Command
**Current bug:** Sending `37 00 80 ff ff ff ff ff ff` — the 0xFF padding is wrong.
**Correct frame:** CMD_SEND_CONTROL_DATA (code 0x37/55):
```
CMD_SEND_CONTROL_DATA {
  code: byte = 0x37 (55)
  flags: byte = 0x00
  sub_type: byte = 0x80  // DISCOVER_REQ
  payload: bytes  // should be EMPTY for a basic discover, not 0xFF padding
}
```
**Try sending just 3 bytes:** `0x37 0x00 0x80` (no payload)

### 3.2 Handle Discover Responses
Responses arrive via PUSH_CODE_CONTROL_DATA (0x8E):
```
PUSH_CODE_CONTROL_DATA {
  code: byte = 0x8E
  SNR_mult_4: signed byte  // SNR * 4
  RSSI: signed byte
  path_len: byte
  path: bytes(path_len)    // skip if path_len is 0
  payload: bytes           // remainder — contains discover response data
}
```
Display discovered nodes in a "Discover" screen showing: node name, type, SNR, RSSI, distance

---

## PRIORITY 4: ALL PUSH NOTIFICATION HANDLERS

Handle ALL push codes. The full list from the firmware source:

### Already Handled ✅
- 0x82 PUSH_CODE_SEND_CONFIRMED
- 0x83 PUSH_CODE_MSG_WAITING
- 0x85 PUSH_CODE_LOGIN_SUCCESS
- 0x86 PUSH_CODE_LOGIN_FAIL

### Need to Implement:

**0x80 — PUSH_CODE_ADVERT**
Known contact sent advertisement. Contains 32-byte public key.
Action: Trigger incremental contact sync with 'since' param to get updated info.

**0x81 — PUSH_CODE_PATH_UPDATED**
Route to contact changed. Contains 32-byte public key.
Action: Trigger incremental contact sync with 'since' param.

**0x84 — PUSH_CODE_RAW_DATA**
Raw LoRa packet received.
```
PUSH_CODE_RAW_DATA {
  code: byte = 0x84
  SNR_mult_4: signed byte
  RSSI: signed byte
  reserved: byte = 0xFF
  payload: bytes  // remainder
}
```
Action: Log for debugging. Could display in advanced "packet log" view later.

**0x87 — PUSH_CODE_STATUS_RESPONSE**
Server/repeater status response.
```
PUSH_CODE_STATUS_RESPONSE {
  code: byte = 0x87
  reserved: byte = 0
  pub_key_prefix: bytes(6)
  status_data: bytes  // remainder
}
```
Action: Display in repeater/sensor management view.

**0x88 — PUSH_CODE_LOG_RX_DATA** (was "undocumented" — now identified!)
Debug log of received LoRa packet. This is what we've been silently ignoring.
Action: Can continue to silently ignore, or display in a debug/packet log view.

**0x89 — PUSH_CODE_TRACE_DATA**
Path trace result.
```
PUSH_CODE_TRACE_DATA {
  code: byte = 0x89
  reserved: byte = 0
  path_len: byte
  flags: byte = 0
  tag: int32
  auth_code: int32
  path_hashes: bytes(path_len)
  path_snrs: bytes(path_len + 1)  // each = SNR * 4, last is final hop SNR
}
```
Action: Display visual trace route.

**0x8A — PUSH_CODE_NEW_ADVERT**
New contact discovered (when manual_add_contacts=1). Same format as RESP_CODE_CONTACT.
Action: Show in "Pending Contacts" section for user to accept or reject.

**0x8B — PUSH_CODE_TELEMETRY_RESPONSE**
Telemetry data from sensor node.
```
PUSH_CODE_TELEMETRY_RESPONSE {
  code: byte = 0x8B
  reserved: byte = 0
  pub_key_prefix: bytes(6)
  LPP_sensor_data: bytes  // Cayenne LPP format, remainder
}
```
Action: Parse and display sensor data (temperature, humidity, battery, etc.)

**0x8C — PUSH_CODE_BINARY_RESPONSE**
Binary request response.
```
PUSH_CODE_BINARY_RESPONSE {
  code: byte = 0x8C
  reserved: byte = 0
  tag: uint32  // match to RESP_CODE_SENT expected_ack_or_tag
  response_data: bytes  // remainder
}
```
Action: Match tag to pending binary request and process.

**0x8D — PUSH_CODE_PATH_DISCOVERY_RESPONSE** (new — not in wiki yet)
Path discovery result.
Action: Display path information for contact.

**0x8E — PUSH_CODE_CONTROL_DATA**
Control packet received (discover responses, etc.)
Structure: see Discover section above.

**0x8F — PUSH_CODE_CONTACT_DELETED** (new — not in wiki yet)
Contact was evicted from the device (when storage is full and a new contact is added).
Action: Show notification "Contact [name] was removed from device to make room for new contacts."

**0x90 — PUSH_CODE_CONTACTS_FULL** (new — not in wiki yet)
Contact storage is completely full.
Action: Show warning "Contact storage is full ([max] contacts). New contacts cannot be added."

---

## PRIORITY 5: ADDITIONAL PROTOCOL COMMANDS

### 5.1 Status Request (CMD_SEND_STATUS_REQ = 0x1B / 27)
```
CMD_SEND_STATUS_REQ {
  code: byte = 0x1B (27)
  pub_key: bytes(32)  // full 32-byte public key of repeater/sensor
}
```
- Add "Request Status" button on repeater and sensor contact views
- Response via PUSH_CODE_STATUS_RESPONSE (0x87)

### 5.2 Telemetry Request (CMD_SEND_TELEMETRY_REQ = 0x27 / 39)
```
CMD_SEND_TELEMETRY_REQ {
  code: byte = 0x27 (39)
  reserved: bytes(3) = zeros
  pub_key: bytes(32)
}
```
- Add "Request Telemetry" button on sensor contacts (type=4)
- Response via PUSH_CODE_TELEMETRY_RESPONSE (0x8B)
- Parse Cayenne LPP format for sensor data

### 5.3 Binary Request (CMD_SEND_BINARY_REQ = 0x32 / 50)
```
CMD_SEND_BINARY_REQ {
  code: byte = 0x32 (50)
  pub_key: bytes(32)
  request_code_and_params: bytes  // remainder
}
```
- Generic binary request — can be used instead of telemetry request
- Response via PUSH_CODE_BINARY_RESPONSE (0x8C), matched by tag

### 5.4 Trace Route (CMD_SEND_TRACE_PATH = 0x24 / 36)
```
CMD_SEND_TRACE_PATH {
  code: byte = 0x24 (36)
  tag: int32          // random, set by initiator
  auth_code: int32    // optional authentication
  flags: byte = 0
  path: bytes         // hashes of nodes for trace to follow
}
```
- Add "Trace Route" in contact context menu
- Response via PUSH_CODE_TRACE_DATA (0x89)
- Display visual path: Node A →(SNR)→ Repeater B →(SNR)→ Node C

### 5.5 Advert Path Query (CMD_GET_ADVERT_PATH = 0x2A / 42)
```
CMD_GET_ADVERT_PATH {
  code: byte = 0x2A (42)
  reserved: byte = 0
  pub_key: bytes(32)
}
```
Response: RESP_CODE_ADVERT_PATH (code 0x16 / 22):
```
RESP_CODE_ADVERT_PATH {
  code: byte = 0x16 (22)
  recv_timestamp: uint32
  path_len: byte
  path: bytes(path_len)
}
```
- Show "Last Known Path" in contact detail view

### 5.6 Auto-Add Configuration (CMD_SET_AUTOADD_CONFIG = 0x3A / 58)
```
CMD_SET_AUTOADD_CONFIG {
  code: byte = 0x3A (58)
  bitmask: byte  // auto-add bitmask
}
```
Response: RESP_CODE_AUTOADD_CONFIG (code 0x19 / 25)
- Bitmask controls which contact types are auto-added
- Add to device settings under "Privacy & Security"

### 5.7 Allowed Repeat Frequencies (CMD_GET_ALLOWED_REPEAT_FREQ = 0x3C / 60)
```
CMD_GET_ALLOWED_REPEAT_FREQ {
  code: byte = 0x3C (60)
}
```
Response: RESP_ALLOWED_REPEAT_FREQ (code 0x1A / 26):
```
RESP_ALLOWED_REPEAT_FREQ {
  code: byte = 0x1A (26)
  ranges: array of {
    lower_freq: uint32  // Freq * 1000
    upper_freq: uint32  // Freq * 1000
  }
}
```
- Show in radio settings when repeat mode is enabled

### 5.8 Signed Messages (TXT_TYPE = 2)
- When receiving messages with txt_type=2 (TXT_TYPE_SIGNED_PLAIN), show a "Verified ✓" badge
- When sending, optionally support signed messages

### 5.9 Raw Data Send (CMD_SEND_RAW_DATA = 0x19 / 25)
```
CMD_SEND_RAW_DATA {
  code: byte = 0x19 (25)
  path_len: byte
  path: bytes(path_len)
  payload: bytes  // remainder
}
```
- Advanced feature, low priority — for custom packet injection

---

## PRIORITY 6: UI/UX POLISH

### 6.1 Remote Management Polish
- [ ] Lazy-load admin settings — only fetch "ver" and "clock" on login, fetch rest when admin menu opened
- [ ] Toggle buttons for all on/off options — bright teal = active, dimmed gray = inactive
- [ ] Distinct toolbar icons: local settings = gearshape, remote management = wrench.and.screwdriver
- [ ] Clock sync warning — if device clock >24h off, show ⚠️ with "Sync Clock" button
- [ ] Permission-based UI: Guest=view only, Read-only=view settings, Read-write=edit most, Admin=full access
- [ ] Auto-update sidebar when login state changes
- [ ] Session timeout detection — if CLI command gets no response after inactivity, prompt re-login

### 6.2 Battery Chemistry
- [ ] Picker in settings: LiPo/NMC (default), LiFePO4, Li-Ion 18650
- [ ] Voltage-to-percentage curves per chemistry (see earlier conversation for exact curves)
- [ ] ADC multiplier for remote devices via CLI: "set adc.multiplier {factor}"

### 6.3 General UI
- [ ] Empty state screens: no connection, no contacts, no messages
- [ ] Pull-to-refresh in contact list and chat
- [ ] Keyboard handling — chat input above keyboard, dismiss on scroll, send on Return
- [ ] All list rows fully tappable: .contentShape(Rectangle()) + Spacer()
- [ ] Message character count (max 160 for DM)
- [ ] Haptic feedback on message send (iOS)

---

## PRIORITY 7: iOS DEPLOYMENT & BACKGROUND BLE

### 7.1 Pre-deployment Verification
- [ ] ios/Info.plist: UIBackgroundModes with bluetooth-central
- [ ] ios/Info.plist: NSBluetoothAlwaysUsageDescription
- [ ] CBCentralManager initialized with CBCentralManagerOptionRestoreIdentifierKey
- [ ] centralManager(_:willRestoreState:) implemented — re-subscribes to NUS TX
- [ ] Auto-reconnect: centralManager(_:didDisconnectPeripheral:) calls central.connect()
- [ ] Local notifications via UNUserNotificationCenter for background messages
- [ ] Notification permission requested on first launch
- [ ] NavigationSplitView works on iPhone (compact width = stack navigation)
- [ ] Build clean: xcodebuild -scheme MeshCoreApple -destination 'generic/platform=iOS' build

### 7.2 iPhone Test Procedure
1. Connect iPhone via USB, enable Developer Mode (Settings → Privacy & Security → Developer Mode)
2. Xcode: Signing & Capabilities → Automatically manage signing → Personal Team
3. Bundle ID: com.mbedworth.meshcore
4. Build and run (Cmd+R)
5. Trust certificate: Settings → General → VPN & Device Management
6. Connect to Mesh Pocket, send test message, verify delivery
7. Background app, wait 20+ minutes
8. Have someone send mesh message → verify notification + connection alive

---

## PRIORITY 8: FUTURE FEATURES

- [ ] Map view with MapKit — plot contacts/repeaters/room servers from lat/lon
- [ ] Offline map tile caching
- [ ] watchOS app — minimal messaging + complications + background BLE (Series 6+)
- [ ] Internet map integration (meshcore.dev/map)
- [ ] Contact sharing via QR code / AirDrop
- [ ] OTA firmware update
- [ ] Keychain storage for credentials and secrets
- [ ] Face ID / Touch ID app lock option
- [ ] Encrypted local database (SQLCipher or Data Protection)
- [ ] TestFlight beta distribution ($99/year Apple Developer Program required)
- [ ] App Store submission with privacy policy

---

## REFERENCE: COMPLETE COMMAND CODE TABLE

| Dec | Hex | Name | Status |
|-----|------|------|--------|
| 1 | 0x01 | CMD_APP_START | ✅ |
| 2 | 0x02 | CMD_SEND_TXT_MSG | ✅ |
| 3 | 0x03 | CMD_SEND_CHANNEL_TXT_MSG | ✅ (needs channel_idx fix) |
| 4 | 0x04 | CMD_GET_CONTACTS | ✅ |
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
| 31 | 0x1F | CMD_GET_CHANNEL | ❌ **CRITICAL** |
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
| 55 | 0x37 | CMD_SEND_CONTROL_DATA | ⚠️ wrong frame |
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
| 18 | 0x12 | RESP_CODE_CHANNEL_INFO | ❌ **CRITICAL** |
| 19 | 0x13 | RESP_CODE_SIGN_START | ❌ |
| 20 | 0x14 | RESP_CODE_SIGNATURE | ❌ |
| 21 | 0x15 | RESP_CODE_CUSTOM_VARS | ✅ |
| 22 | 0x16 | RESP_CODE_ADVERT_PATH | ❌ |
| 23 | 0x17 | RESP_CODE_TUNING_PARAMS | ✅ |
| 24 | 0x18 | RESP_CODE_STATS | ✅ |
| 25 | 0x19 | RESP_CODE_AUTOADD_CONFIG | ❌ |
| 26 | 0x1A | RESP_ALLOWED_REPEAT_FREQ | ❌ |
| 128 | 0x80 | PUSH_CODE_ADVERT | ❌ |
| 129 | 0x81 | PUSH_CODE_PATH_UPDATED | ❌ |
| 130 | 0x82 | PUSH_CODE_SEND_CONFIRMED | ✅ |
| 131 | 0x83 | PUSH_CODE_MSG_WAITING | ✅ |
| 132 | 0x84 | PUSH_CODE_RAW_DATA | ❌ |
| 133 | 0x85 | PUSH_CODE_LOGIN_SUCCESS | ✅ |
| 134 | 0x86 | PUSH_CODE_LOGIN_FAIL | ✅ |
| 135 | 0x87 | PUSH_CODE_STATUS_RESPONSE | ❌ |
| 136 | 0x88 | PUSH_CODE_LOG_RX_DATA | ⚠️ identified, log+ignore |
| 137 | 0x89 | PUSH_CODE_TRACE_DATA | ❌ |
| 138 | 0x8A | PUSH_CODE_NEW_ADVERT | ❌ |
| 139 | 0x8B | PUSH_CODE_TELEMETRY_RESPONSE | ❌ |
| 140 | 0x8C | PUSH_CODE_BINARY_RESPONSE | ❌ |
| 141 | 0x8D | PUSH_CODE_PATH_DISCOVERY_RESPONSE | ❌ |
| 142 | 0x8E | PUSH_CODE_CONTROL_DATA | ❌ |
| 143 | 0x8F | PUSH_CODE_CONTACT_DELETED | ❌ |
| 144 | 0x90 | PUSH_CODE_CONTACTS_FULL | ❌ |
