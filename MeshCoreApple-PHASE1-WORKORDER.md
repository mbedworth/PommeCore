# MeshCoreApple — Phase 1 Work Order
## For Claude Code — Execute in order, commit after each section

**Project:** ~/Developer/MeshCoreApple
**Date:** March 14, 2026
**Goal:** Fix all blocking bugs and add favourite contacts to get the app ready for real-world field testing.

---

## SECTION A: GLOBAL TIMEOUT FIX (Do this FIRST — it fixes 7+ features at once)

### Problem
Every activity indicator timeout in the app gets stuck. The timeout Task fires but doesn't update @Published properties on MainActor, so the UI overlay never dismisses. This affects: status request, telemetry, trace route, path info, discover, login, and CLI commands.

### Fix — Create a reusable pattern and apply everywhere

1. **Create a reusable ActivityOverlay view** if one doesn't exist:

```swift
struct ActivityOverlay: View {
    let message: String
    let timeoutSeconds: TimeInterval
    @State private var elapsed: TimeInterval = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("\(Int(elapsed))s / \(Int(timeoutSeconds))s")
                .font(.caption)
                .foregroundColor(.tertiary)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onReceive(timer) { _ in
            if elapsed < timeoutSeconds {
                elapsed += 1
            }
        }
    }
}
```

2. **Fix the timeout pattern** — Search the ENTIRE codebase for every `Task.sleep` or timeout handler that updates UI state. Every single one must use this pattern:

```swift
timeoutTask = Task {
    try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
    if !Task.isCancelled {
        await MainActor.run {
            self.isActivityInProgress = false      // dismiss overlay
            self.activityResultMessage = "Timed out — no response received."
            self.activityResultType = .timeout      // for styling
        }
    }
}
```

3. **When a successful response arrives**, cancel the timeout and update on MainActor:

```swift
func handleSuccessResponse(...) {
    timeoutTask?.cancel()
    Task { @MainActor in
        self.isActivityInProgress = false
        self.activityResultMessage = "Success — ..."
        self.activityResultType = .success
    }
}
```

4. **Verify and fix ALL of these timeout handlers:**
   - [ ] Status request timeout (15s)
   - [ ] Telemetry request timeout (15s) 
   - [ ] Trace route timeout (15s)
   - [ ] Path info / Show Path timeout (10s)
   - [ ] Discover timeout (30s)
   - [ ] Login timeout (use suggested_timeout from RESP_CODE_SENT + 3s, or 15s default)
   - [ ] CLI command timeout (8s per command)
   - [ ] Settings fetch timeout (8s per CLI get command)

**Test:** After this fix, every activity overlay in the app should count up and then dismiss cleanly with a result message when the timeout is reached. No more stuck spinners.

Commit: "fix: global timeout handler — all activity indicators now dismiss on MainActor"

---

## SECTION B: BLE DISCONNECT LIFECYCLE (Fixes 1.1, 1.2, 1.3a)

These three bugs are all related to the BLE connection lifecycle being messy. Fix them together.

### B1: Create a clean disconnect function

```swift
/// Central disconnect function — ALL disconnects go through here
func disconnect(reason: DisconnectReason = .userInitiated) {
    guard let peripheral = connectedPeripheral else { return }
    
    // 1. Cancel any pending operations
    timeoutTask?.cancel()
    pendingCLICommands.removeAll()
    pendingACKs.removeAll()
    activeManagementPubkey = nil
    loginStates.removeAll()
    
    // 2. Clear characteristic references
    nusRXCharacteristic = nil
    nusTXCharacteristic = nil
    
    // 3. Request BLE disconnection
    centralManager.cancelPeripheralConnection(peripheral)
    
    // 4. DO NOT clear connectedPeripheral here — wait for didDisconnectPeripheral callback
    // The callback will handle cleanup and auto-reconnect logic
    
    disconnectReason = reason
}

enum DisconnectReason {
    case userInitiated      // User pressed disconnect button
    case unexpected         // BLE dropped unexpectedly
    case appTermination     // App is being terminated
}
```

### B2: Fix didDisconnectPeripheral callback

```swift
func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    Task { @MainActor in
        self.connectedPeripheral = nil
        self.isConnected = false
        self.connectionState = .disconnected
        
        if let error = error, disconnectReason != .userInitiated {
            // Unexpected disconnect — attempt auto-reconnect
            self.connectionState = .reconnecting
            await autoReconnect(peripheral: peripheral, attempts: 3)
        } else {
            // User-initiated or clean disconnect — start scanning after 2s
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled {
                self.startScanning()
            }
        }
    }
}

func autoReconnect(peripheral: CBPeripheral, attempts: Int) async {
    for attempt in 1...attempts {
        await MainActor.run {
            self.connectionState = .reconnecting
            self.reconnectAttempt = attempt
        }
        centralManager.connect(peripheral, options: nil)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        
        if isConnected { return }  // reconnected successfully
    }
    // All attempts failed — give up and start scanning
    await MainActor.run {
        self.connectionState = .disconnected
        self.startScanning()
    }
}
```

### B3: Fix the radio/broadcast icon (Bug 1.1)

Find the toolbar button that has the radio/broadcast icon ((•)) or antenna icon. Currently it disconnects. Change it to send a self-advertisement:

```swift
// WRONG — this is what it does now (disconnects)
Button(action: { viewModel.disconnect() }) {
    Image(systemName: "antenna.radiowaves.left.and.right")
}

// RIGHT — send self-advertisement
Button(action: { viewModel.sendSelfAdvertisement() }) {
    Image(systemName: "antenna.radiowaves.left.and.right")
}
.help("Send Advertisement — announce your presence on the mesh")
.disabled(!viewModel.isConnected)
```

The `sendSelfAdvertisement()` function should send CMD_SEND_SELF_ADVERT (code 7) and show a brief "Advertisement sent" confirmation toast.

### B4: Fix the status bar tap behavior (Bug 1.2)

Find where the "Connected — MeshCore-XXXX" status bar is tapped. Change the action:

```swift
func onStatusBarTapped() {
    if isConnected {
        showDeviceInfoPopover = true   // show device info (name, firmware, battery, signal)
    } else {
        showScannerSheet = true        // only open scanner when disconnected
    }
}
```

Create a DeviceInfoPopover view that shows: device name, firmware version, battery level, BLE signal strength (RSSI), uptime, storage used, and a "Disconnect" button at the bottom.

Commit: "fix: BLE disconnect lifecycle — clean disconnect, auto-reconnect, correct toolbar behavior"

---

## SECTION C: CONTACT SYNC FIX (Bug 1.3b)

### Problem
Contacts disappear from the sidebar when CLI responses come in during remote admin.

### Fix — Atomic swap pattern

```swift
// In your ViewModel or contact manager:
private var pendingContacts: [Contact] = []

func handleContactsStart(count: Int) {
    pendingContacts = []  // Clear BUFFER only, NOT the displayed contacts
}

func handleContact(contact: Contact) {
    pendingContacts.append(contact)
}

func handleEndOfContacts(lastmod: UInt32) {
    Task { @MainActor in
        self.contacts = self.pendingContacts  // Single atomic swap — one UI update
        self.pendingContacts = []
        self.lastContactSyncMod = lastmod
    }
}
```

**Also add guards on what triggers contact re-sync.** Only these events should trigger CMD_GET_CONTACTS:
- Initial BLE connection established
- PUSH_CODE_ADVERT (0x80) received
- PUSH_CODE_PATH_UPDATED (0x81) received
- User pulls to refresh or taps a refresh button

**NEVER trigger contact re-sync from:**
- CLI response handling (txt_type=1 messages)
- Message sync (CMD_SYNC_NEXT_MESSAGE responses)
- Any other response parsing

Search the codebase for every call to the function that sends CMD_GET_CONTACTS and verify each call site is on the allowed list. Remove any that aren't.

Commit: "fix: atomic contact swap — contacts no longer disappear during remote admin"

---

## SECTION D: ROOM SERVER FIXES (Bugs 1.5, 1.6)

### D1: Room server name in chat header (Bug 1.5)

When a room server contact (type=3) is selected and the chat view loads, display the contact's adv_name in the chat header/navigation title. Find the chat view's title/header and make sure it uses the selected contact's name:

```swift
.navigationTitle(selectedContact?.advName ?? "Chat")
// or if you have a custom header:
Text(selectedContact?.advName ?? "Chat")
    .font(.headline)
```

### D2: Require login before messaging room servers (Bug 1.6)

In the chat view, when the selected contact is type=3 (room server):

```swift
// In the message input area:
if selectedContact?.type == 3 && !isLoggedIn(to: selectedContact) {
    // Show disabled state
    HStack {
        Text("Login required to send messages")
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
        Button("Login") {
            showLoginSheet = true
        }
        .buttonStyle(.borderedProminent)
    }
    .padding()
} else {
    // Normal message input
    MessageInputView(...)
}
```

Also guard the send function:

```swift
func sendMessage(to contact: Contact, text: String) {
    if contact.type == 3 && !isLoggedIn(to: contact) {
        showLoginRequired = true
        return
    }
    // ... normal send logic
}
```

Commit: "fix: room server name in header, login required before messaging"

---

## SECTION E: TRACE ROUTE & TELEMETRY FIXES (Bugs 1.7, 1.8, 1.9)

### E1: Trace route (Bug 1.7)

1. **Pre-send validation:**
```swift
func traceRoute(to contact: Contact) {
    if contact.pathLen == 0 {
        showResult("This contact is a direct neighbor — no hops to trace.")
        return
    }
    if contact.pathLen == 0xFF || contact.pathLen == -1 {
        showResult("No known route to this contact.")
        return
    }
    // Only include actual path bytes, no zero padding
    let pathData = contact.outPath.prefix(Int(contact.pathLen))
    sendTracePathCommand(tag: generateTag(), pathData: pathData)
}
```

2. **Fix frame builder** — Only send `path_len` bytes of actual path data, not padded zeros.

3. **Implement PUSH_CODE_TRACE_DATA (0x89) parser:**
```
Frame: code(0x89), reserved(1 byte), path_len(1 byte), flags(1 byte), 
       tag(4 bytes int32), auth_code(4 bytes int32), 
       path_hashes(path_len bytes), path_snrs(path_len+1 bytes, each = SNR*4)
```
Display as a visual trace: "You → [hop1 SNR] → [hop2 SNR] → [destination SNR]"

4. **Timeout handler** — Uses the global fix from Section A.

### E2: Telemetry (Bug 1.8)

1. **Add contextual messaging before sending:**
```swift
func requestTelemetry(from contact: Contact) {
    let message: String
    switch contact.type {
    case 1: message = "Telemetry is typically only available from sensor nodes. This chat node may not respond."
    case 2: message = "Some repeaters support basic telemetry. Waiting for response..."
    case 3: message = "Room servers don't typically support telemetry."
    case 4: message = "Requesting telemetry from sensor..."
    default: message = "Requesting telemetry..."
    }
    showActivity(message: message, timeout: 15)
    sendTelemetryRequest(to: contact)
}
```

2. **Implement PUSH_CODE_TELEMETRY_RESPONSE (0x8B) parser:**
```
Frame: code(0x8B), reserved(1 byte), pub_key_prefix(6 bytes), LPP_sensor_data(remainder)
```
Parse Cayenne LPP format for sensor values (temperature, humidity, pressure, GPS, etc.)

3. **Timeout message:** "No telemetry response — this node may not support telemetry or is out of range."

### E3: Show Path (Bug 1.9)

1. **Fix frame:** code(0x2A) + reserved(0x00) + pub_key(32 bytes) = 34 bytes total

2. **Graceful fallback** — CMD_GET_ADVERT_PATH is NOT supported on FW v1.14.0:
```swift
func showPath(for contact: Contact) {
    // Try the command first
    sendGetAdvertPath(for: contact)
    
    // Set a short timeout (5s) — if unsupported, fall back to local data
    pathTimeoutTask = Task {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        if !Task.isCancelled {
            await MainActor.run {
                // Fall back to local out_path data
                self.displayLocalPath(for: contact)
            }
        }
    }
}

func displayLocalPath(for contact: Contact) {
    if contact.pathLen == 0 {
        pathResult = "Direct neighbor (0 hops)"
    } else if contact.pathLen == 0xFF {
        pathResult = "No known path"
    } else {
        let hops = contact.outPath.prefix(Int(contact.pathLen))
        let hopStrings = hops.map { String(format: "%02X", $0) }
        pathResult = "\(contact.pathLen) hop(s): \(hopStrings.joined(separator: " → "))"
    }
    isActivityInProgress = false
}
```

Also handle RESP_CODE_ERR for this command — if err_code=1 (Unsupported), immediately fall back to local path display.

Commit: "fix: trace route validation + telemetry context + show path fallback"

---

## SECTION F: CLI RESPONSE ROUTING (Bug 1.11)

### Problem
Remote management settings fields show placeholders or spinning indicators because CLI responses aren't being routed correctly.

### Fix

1. **After sending each CLI command** (txt_type=1), poll for the response:
```swift
func sendCLICommand(_ command: String, to contact: Contact) {
    // Send the CLI command as txt_type=1
    sendTextMessage(to: contact, text: command, txtType: 1)
    
    // Add to pending queue
    pendingCLICommands.append(PendingCLICommand(
        command: command,
        sentAt: Date(),
        targetPubkey: contact.publicKey
    ))
    
    // Poll for response after 500ms
    Task {
        try? await Task.sleep(nanoseconds: 500_000_000)
        sendSyncNextMessage()
    }
    
    // Set 8s timeout per command
    startCLITimeout(for: command, seconds: 8)
}
```

2. **Route CLI responses to management UI, NOT chat:**
```swift
func handleReceivedMessage(senderPubkey: Data, text: String, txtType: UInt8) {
    if txtType == 1 && senderPubkey == activeManagementPubkey {
        // This is a CLI response — route to management
        let responseText = text.hasPrefix("> ") ? String(text.dropFirst(2)) : text
        
        if let pending = pendingCLICommands.first {
            pendingCLICommands.removeFirst()
            handleCLIResponse(command: pending.command, response: responseText)
            // Also display in CLI terminal section
            cliTerminalHistory.append(CLIEntry(command: pending.command, response: responseText))
        }
        
        // Do NOT show as a chat message
        return
    }
    
    // Normal chat message handling
    // ...
}
```

3. **Parse CLI responses and populate settings fields:**
```swift
func handleCLIResponse(command: String, response: String) {
    Task { @MainActor in
        switch command {
        case "ver": self.remoteVersion = response
        case "clock": self.remoteClock = response
        case "get radio": self.parseRadioSettings(response)
        case "get tx": self.remoteTxPower = response
        case "get name": self.remoteName = response
        case "get lat": self.remoteLatitude = response
        case "get lon": self.remoteLongitude = response
        case "get owner.info": self.remoteOwnerInfo = response
        case "neighbors": self.parseNeighbors(response)
        case "get acl": self.parseACL(response)
        // ... add all other CLI commands
        default: break
        }
    }
}
```

4. Replace all spinning indicators with either the actual value or "Timeout" after 8 seconds.

Commit: "fix: CLI response routing — remote management settings now populate correctly"

---

## SECTION G: FAVOURITE CONTACTS (New feature for field testing)

### G1: Data model — add isFavourite to Contact

Make sure the Contact model has a `flags` field parsed from the protocol, and expose a computed `isFavourite`:

```swift
struct Contact: Identifiable {
    // ... existing fields
    let flags: UInt8  // From protocol — bit 0 = favourite
    
    var isFavourite: Bool {
        return (flags & 0x01) != 0
    }
}
```

### G2: Toggle favourite — write back to radio

```swift
func toggleFavourite(for contact: Contact) {
    var newFlags = contact.flags
    if contact.isFavourite {
        newFlags &= ~0x01  // Clear bit 0
    } else {
        newFlags |= 0x01   // Set bit 0
    }
    
    // Send CMD_ADD_UPDATE_CONTACT (0x09) with updated flags
    // Frame: code(0x09) + pub_key(32 bytes) + adv_name(32 bytes) + flags(1 byte)
    sendAddUpdateContact(
        publicKey: contact.publicKey,
        advName: contact.advName,
        flags: newFlags
    )
    
    // Optimistically update local state
    Task { @MainActor in
        if let index = self.contacts.firstIndex(where: { $0.publicKey == contact.publicKey }) {
            self.contacts[index] = contact.withFlags(newFlags)
        }
    }
}
```

### G3: Read favourites from radio on contact sync

When parsing RESP_CODE_CONTACT (0x03) responses, make sure the `flags` byte is parsed and stored. It's already in the contact response frame — verify it's being read.

### G4: Sort favourites to top of sidebar

```swift
var sortedContacts: [Contact] {
    contacts.sorted { a, b in
        if a.isFavourite != b.isFavourite {
            return a.isFavourite  // Favourites first
        }
        return a.displayName < b.displayName  // Then alphabetical
    }
}
```

### G5: UI — Star icon in contact list and context menu

```swift
// In contact list row:
HStack {
    // Contact type icon (person/antenna/server/sensor)
    contactTypeIcon(contact)
    
    VStack(alignment: .leading) {
        Text(contact.displayName)
            .font(.headline)
        Text(contact.statusText)
            .font(.caption)
            .foregroundColor(.secondary)
    }
    
    Spacer()
    
    if contact.isFavourite {
        Image(systemName: "star.fill")
            .foregroundColor(.yellow)
            .font(.caption)
    }
}
.contextMenu {
    Button(action: { viewModel.toggleFavourite(for: contact) }) {
        Label(
            contact.isFavourite ? "Remove from Favourites" : "Add to Favourites",
            systemImage: contact.isFavourite ? "star.slash" : "star"
        )
    }
    // ... other context menu items
}
```

### G6: Swipe action for quick favourite toggle (iOS)

```swift
.swipeActions(edge: .leading) {
    Button(action: { viewModel.toggleFavourite(for: contact) }) {
        Label(
            contact.isFavourite ? "Unfavourite" : "Favourite",
            systemImage: contact.isFavourite ? "star.slash" : "star.fill"
        )
    }
    .tint(.yellow)
}
```

Commit: "feat: favourite contacts — star toggle syncs to radio, favourites sorted to top"

---

## SECTION H: COMPILER WARNINGS (Bug 1.4)

### H1: Logger nonisolated(unsafe) warning

In MeshCoreViewModel.swift, find:
```swift
nonisolated(unsafe) static let logger = Logger(...)
```

Change to:
```swift
static let logger = Logger(...)
```

Logger is already Sendable, so the attribute is unnecessary.

### H2: AppIcon unassigned children

1. List actual PNG files in the AppIcon.appiconset directory
2. Open AppIcon.appiconset/Contents.json  
3. Remove ALL image entries that reference a filename that doesn't exist on disk
4. For Xcode 15+ single-size icon, keep just one entry:

```json
{
  "images" : [
    {
      "filename" : "AppIcon.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

Adjust the filename to match whatever 1024x1024 PNG actually exists in the directory.

Commit: "fix: resolve all compiler warnings (Logger sendable, AppIcon assets)"

---

## SECTION I: CONTEXTUAL MESSAGING FOR STATUS REQUESTS

When a user sends a status request, add contextual guidance:

```swift
func requestStatus(from contact: Contact) {
    let message: String
    switch contact.type {
    case 1: message = "Status requests are only supported by repeaters, room servers, and sensors. This chat node may not respond."
    case 2: message = "Requesting status from repeater..."
    case 3: message = "Requesting status from room server..."
    case 4: message = "Requesting status from sensor..."
    default: message = "Requesting status..."
    }
    showActivity(message: message, timeout: 15)
    sendStatusRequest(to: contact)
}
```

Commit: "feat: contextual messaging for status requests by node type"

---

## FINAL: Build verification

After all sections are complete:

1. Clean build: `xcodebuild clean build -scheme MeshCoreApple -destination 'platform=macOS'`
2. Verify zero warnings (or only unavoidable system warnings)
3. Run on Mac, connect to Mesh Pocket, verify:
   - [ ] Broadcast icon sends advertisement (not disconnect)
   - [ ] Connected status bar tap shows device info (not scanner)
   - [ ] Disconnect button cleanly disconnects, auto-scans after 2s
   - [ ] Contacts persist in sidebar during remote admin CLI commands
   - [ ] Room server chat shows name in header
   - [ ] Room server requires login before messaging
   - [ ] All timeouts dismiss cleanly with result messages
   - [ ] Star a contact → verify it moves to top of list
   - [ ] Star a contact → reconnect → verify star persists (read from radio)
   - [ ] CLI commands populate remote management settings

Commit: "chore: Phase 1 complete — all blocking bugs fixed, favourites working"
Push to GitHub.
