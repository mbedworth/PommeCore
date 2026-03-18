# MeshCoreApple — Phase 3 Work Order
## From Functional to Publicly Distributable
## For Claude Code — Execute in order, commit after each section

**Project:** ~/Developer/MeshCoreApple
**Date:** March 14, 2026
**Goal:** Take the app from "works on my Mac" to "ready for TestFlight and public distribution." This phase covers theme support, iOS deployment with background BLE, empty states, settings help text, the discover fallback, remaining push handlers that complete half-built features, message polish, and all TestFlight prerequisites.

After this phase, the app should be competitive with Meshtastic's Apple client for the feature set it covers, and ready for beta testers.

---

## SECTION A: THEME SUPPORT (Light / Dark / System)

### A1: Color audit

Search the entire codebase for hardcoded colors. Replace any that won't adapt to dark mode:

```swift
// WRONG — hardcoded colors that break in dark mode
Color.white          // invisible on dark backgrounds
Color.black          // invisible on light backgrounds
Color(hex: "F5F5F5") // hardcoded light gray background
Color(hex: "333333") // hardcoded dark text

// RIGHT — adaptive system colors
Color.primary           // text — adapts automatically
Color.secondary         // secondary text
Color(.systemBackground)       // main background
Color(.secondarySystemBackground) // cards, sidebars
Color(.tertiarySystemBackground)  // nested elements
Color(.separator)       // dividers
Color.accentColor       // interactive elements (uses app tint)
```

**Specific things to check and fix:**
- Chat bubble backgrounds (sender vs receiver) — should use distinct but adaptive colors
- Sidebar background
- Navigation bar / toolbar background
- Settings section backgrounds
- Remote management section backgrounds  
- Status badges (online/offline/connecting)
- The activity overlay background
- Any custom hex colors in the app

**For chat bubbles specifically:**
```swift
// Sender bubble (your messages)
.background(Color.accentColor.opacity(0.15))  // tinted, adapts to theme

// Receiver bubble (their messages)  
.background(Color(.secondarySystemBackground))  // neutral, adapts to theme
```

### A2: App-level theme preference

Add a theme setting to the app preferences:

```swift
enum AppTheme: String, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil          // follow system
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// Store in UserDefaults (or @AppStorage)
@AppStorage("appTheme") var appTheme: String = AppTheme.system.rawValue

var selectedTheme: AppTheme {
    AppTheme(rawValue: appTheme) ?? .system
}
```

### A3: Apply at app root

In the main App struct or root ContentView, apply the preferred color scheme:

```swift
@main
struct MeshCoreApp: App {
    @AppStorage("appTheme") var appTheme: String = AppTheme.system.rawValue
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(AppTheme(rawValue: appTheme)?.colorScheme)
        }
    }
}
```

When `colorScheme` is `nil` (system mode), SwiftUI follows the OS setting automatically.

### A4: Theme picker in settings

Add a theme selector to the app's settings view:

```swift
Section("Appearance") {
    Picker("Theme", selection: $appTheme) {
        ForEach(AppTheme.allCases, id: \.rawValue) { theme in
            Text(theme.rawValue).tag(theme.rawValue)
        }
    }
    .pickerStyle(.segmented)  // Shows System | Light | Dark as a segmented control
}
```

### A5: Accent color

Define the app's accent color in Assets.xcassets so it adapts to both modes. If one doesn't exist, create an AccentColor color set:
- Light mode: a medium blue or teal (something that's visible on white)
- Dark mode: a brighter version of the same hue (visible on dark backgrounds)

Or use a single color that works on both — teal/cyan tends to work well.

Commit: "feat: theme support — light/dark/system preference with full color audit"

---

## SECTION B: EMPTY STATES AND ONBOARDING GUIDANCE

A publicly distributed app must never show a blank screen with no explanation. Every "empty" state needs helpful guidance.

### B1: No BLE connection

When the app launches and no radio is connected:

```swift
struct NoConnectionView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No Radio Connected")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Turn on your MeshCore radio and tap the status bar above to scan for nearby devices.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

Show this in the main content area when `!isConnected` and no cached state exists.

### B2: Connected but no contacts

After connecting, if the contact list is empty (fresh radio or just wiped):

```swift
VStack(spacing: 16) {
    Image(systemName: "person.2.slash")
        .font(.system(size: 40))
        .foregroundColor(.secondary)
    Text("No Contacts Yet")
        .font(.headline)
    Text("Send an advertisement to announce your presence on the mesh. Other nodes will appear here as they respond.")
        .font(.subheadline)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
    Button(action: { viewModel.sendSelfAdvertisement() }) {
        Label("Send Advertisement", systemImage: "antenna.radiowaves.left.and.right")
    }
    .buttonStyle(.borderedProminent)
}
```

### B3: No messages in chat

When a contact is selected but there are no messages:

```swift
VStack(spacing: 12) {
    Image(systemName: "bubble.left.and.bubble.right")
        .font(.system(size: 36))
        .foregroundColor(.secondary)
    Text("No messages yet")
        .font(.subheadline)
        .foregroundColor(.secondary)
    Text("Send a message to start the conversation.")
        .font(.caption)
        .foregroundColor(.tertiary)
}
.frame(maxWidth: .infinity, maxHeight: .infinity)
```

### B4: No channels

If the channel list is empty after sync:

```swift
VStack(spacing: 12) {
    Image(systemName: "number.square")
        .font(.system(size: 36))
        .foregroundColor(.secondary)
    Text("No channels configured")
        .font(.subheadline)
        .foregroundColor(.secondary)
}
```

Commit: "feat: empty states — helpful guidance for no connection, no contacts, no messages, no channels"

---

## SECTION C: SETTINGS HELP TEXT AND DANGER ZONE

### C1: Section footer help text

Add descriptive footer text to every settings section so users understand the impact of changes:

```swift
// Radio Configuration section
Section {
    // ... radio settings fields
} header: {
    Text("Radio Configuration")
} footer: {
    Text("⚠️ Changing radio parameters will disconnect you from nodes using different settings. All nodes on your mesh must use the same frequency, bandwidth, spreading factor, and coding rate.")
        .font(.caption)
}

// Tuning Parameters section
Section {
    // ... tuning fields
} header: {
    Text("Tuning Parameters")
} footer: {
    Text("Advanced — adjust timing parameters for mesh performance. Default values work well for most setups. Changes take effect immediately.")
        .font(.caption)
}

// Privacy & Security section
Section {
    // ... privacy settings
} header: {
    Text("Privacy & Security")
} footer: {
    Text("Controls what information your device shares on the mesh network and how contacts are managed.")
        .font(.caption)
}

// Danger Zone section
Section {
    Button(role: .destructive, action: { showRebootConfirm = true }) {
        Label("Reboot Device", systemImage: "arrow.clockwise")
    }
    Button(role: .destructive, action: { showFactoryResetConfirm = true }) {
        Label("Factory Reset", systemImage: "exclamationmark.triangle")
    }
} header: {
    Text("Danger Zone")
} footer: {
    Text("⚠️ Factory reset erases all contacts, channels, settings, and encryption keys from the device. This cannot be undone.")
        .font(.caption)
}
```

### C2: Confirmation dialogs for destructive actions

Make sure reboot and factory reset have proper confirmation dialogs:

```swift
.confirmationDialog("Reboot Device?", isPresented: $showRebootConfirm) {
    Button("Reboot", role: .destructive) { viewModel.rebootDevice() }
    Button("Cancel", role: .cancel) {}
} message: {
    Text("The radio will disconnect and restart. You'll need to reconnect via Bluetooth.")
}

.confirmationDialog("Factory Reset?", isPresented: $showFactoryResetConfirm) {
    Button("Factory Reset", role: .destructive) { viewModel.factoryReset() }
    Button("Cancel", role: .cancel) {}
} message: {
    Text("This will erase ALL data on the device — contacts, channels, settings, and encryption keys. This cannot be undone.")
}
```

### C3: Help text on contact context menu actions

Add descriptive labels so users know what each action does:

```swift
.contextMenu {
    Button(action: { /* send message */ }) {
        Label("Send Message", systemImage: "bubble.left")
    }
    
    Divider()
    
    Button(action: { viewModel.traceRoute(to: contact) }) {
        Label("Trace Route", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
    }
    
    Button(action: { viewModel.showPath(for: contact) }) {
        Label("Show Path", systemImage: "arrow.triangle.branch")
    }
    
    if contact.type == 2 || contact.type == 3 || contact.type == 4 {
        Button(action: { viewModel.requestStatus(from: contact) }) {
            Label("Request Status", systemImage: "info.circle")
        }
    }
    
    if contact.type == 4 {
        Button(action: { viewModel.requestTelemetry(from: contact) }) {
            Label("Request Telemetry", systemImage: "thermometer.medium")
        }
    }
    
    Divider()
    
    Button(action: { viewModel.toggleFavourite(for: contact) }) {
        Label(contact.isFavourite ? "Remove from Favourites" : "Add to Favourites",
              systemImage: contact.isFavourite ? "star.slash" : "star")
    }
    
    Button(action: { viewModel.shareContact(contact) }) {
        Label("Share on Mesh", systemImage: "square.and.arrow.up")
    }
    
    Button(action: { viewModel.exportContactLink(contact) }) {
        Label("Copy Link", systemImage: "link")
    }
    
    Button(action: { viewModel.resetPath(for: contact) }) {
        Label("Reset Path", systemImage: "arrow.counterclockwise")
    }
    
    Divider()
    
    Button(role: .destructive, action: { viewModel.removeContact(contact) }) {
        Label("Remove Contact", systemImage: "trash")
    }
}
```

Commit: "feat: settings help text, confirmation dialogs, context menu organization"

---

## SECTION D: DISCOVER FEATURE WITH GRACEFUL FALLBACK

### D1: Implement the discover flow

CMD_SEND_CONTROL_DATA (0x37) is not supported on BLE Companion firmware v1.14.0. The app must gracefully fall back to flood advertisement.

```swift
func discover() {
    showActivity(message: "Scanning for nearby nodes...", timeout: 30)
    discoveredNodes = []
    
    // Try CMD_SEND_CONTROL_DATA first
    let controlFrame = Data([0x37, 0x00, 0x80])  // code + reserved + discover flag
    sendFrame(controlFrame)
    
    // Set a short timeout to detect if the command is unsupported
    discoverFallbackTask = Task {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        if !Task.isCancelled && discoveredNodes.isEmpty {
            // Command likely unsupported — fall back to flood advertisement
            await MainActor.run {
                self.activityMessage = "Using advertisement-based discovery..."
            }
            sendFloodAdvertisement()
        }
    }
    
    // Listen for 30 seconds total for any discovery responses
    discoverTimeoutTask = Task {
        try? await Task.sleep(nanoseconds: 30_000_000_000)
        if !Task.isCancelled {
            await MainActor.run {
                self.isActivityInProgress = false
                if self.discoveredNodes.isEmpty {
                    self.activityResultMessage = "No nearby nodes found. Make sure other MeshCore devices are powered on and in range."
                } else {
                    self.activityResultMessage = "Found \(self.discoveredNodes.count) node(s)."
                }
            }
        }
    }
}

func sendFloodAdvertisement() {
    // CMD_SEND_SELF_ADVERT (0x07) with flood parameter
    var frame = Data([0x07])
    frame.append(0x01)  // flood mode = 1
    sendFrame(frame)
}
```

### D2: Handle RESP_CODE_ERR for unsupported command

When the frame parser receives RESP_CODE_ERR (0x01) with err_code=1 after sending 0x37:

```swift
case 0x01: // RESP_CODE_ERR
    let errCode = payload.count > 0 ? payload[0] : 0xFF
    if errCode == 1 {
        logger.info("Unsupported command — falling back")
        // If we were trying discover, switch to flood advert
        if isDiscoverInProgress {
            discoverFallbackTask?.cancel()
            Task { @MainActor in
                self.activityMessage = "Discover not supported on this firmware. Using advertisement-based discovery..."
            }
            sendFloodAdvertisement()
        }
    }
```

### D3: Collect discovery results from push codes

During the 30-second discover window, collect results from:
- 0x80 PUSH_CODE_ADVERT → known contact updated (already handled in Phase 2, but also feed into discover results)
- 0x8A PUSH_CODE_NEW_ADVERT → new contact discovered
- 0x8E PUSH_CODE_CONTROL_DATA → direct discover response (if firmware supports it)

```swift
// When discover is active, also add responding contacts to the discover results list
func addToDiscoverResults(_ contact: Contact) {
    if isDiscoverInProgress {
        Task { @MainActor in
            if !self.discoveredNodes.contains(where: { $0.publicKey == contact.publicKey }) {
                self.discoveredNodes.append(contact)
            }
        }
    }
}
```

### D4: Remember unsupported state

After the first failed attempt, remember that this firmware doesn't support the command so we skip directly to flood advertisement on subsequent discover requests during this session:

```swift
private var firmwareSupportsDiscover: Bool? = nil  // nil = unknown, test on first attempt

func discover() {
    if firmwareSupportsDiscover == false {
        // Skip directly to flood advertisement
        showActivity(message: "Scanning for nearby nodes via advertisement...", timeout: 30)
        sendFloodAdvertisement()
        return
    }
    // ... try CMD_SEND_CONTROL_DATA first
}
```

Commit: "feat: discover with graceful fallback to flood advertisement"

---

## SECTION E: REMAINING PUSH HANDLERS FOR COMPLETE FEATURES

These push handlers complete features that are already half-built (the send side works but the receive side is missing).

### E1: PUSH_CODE_STATUS_RESPONSE (0x87)

Completes the "Request Status" feature. Without this, the status request sends but the response is never displayed.

```swift
case 0x87: // PUSH_CODE_STATUS_RESPONSE
    if payload.count >= 7 {
        let reserved = payload[0]
        let pubkeyPrefix = payload[1..<7]  // 6-byte public key prefix
        let statusData = payload.suffix(from: 7)
        
        logger.info("PUSH_CODE_STATUS_RESPONSE from \(pubkeyPrefix.hexString)")
        
        // Cancel the status request timeout
        statusTimeoutTask?.cancel()
        
        Task { @MainActor in
            self.isActivityInProgress = false
            // Parse status data — format depends on device type
            // Common fields: uptime, packets_sent, packets_recv, battery, temperature
            self.parseAndDisplayStatus(pubkeyPrefix: pubkeyPrefix, data: statusData)
        }
    }
```

Status data parsing (the format varies, but common fields):
```swift
func parseAndDisplayStatus(pubkeyPrefix: Data, data: Data) {
    // The status response is typically a text string with key:value pairs
    // or a binary format depending on firmware version
    if let text = String(data: data, encoding: .utf8) {
        statusResultMessage = text
    } else {
        statusResultMessage = "Received status: \(data.count) bytes (binary format)"
    }
}
```

### E2: PUSH_CODE_TRACE_DATA (0x89)

Completes the "Trace Route" feature.

```swift
case 0x89: // PUSH_CODE_TRACE_DATA
    if payload.count >= 3 {
        let reserved = payload[0]
        let pathLen = Int(payload[1])
        let flags = payload[2]
        
        var offset = 3
        let tag: UInt32 = payload.count >= offset + 4 ? payload.readUInt32LE(at: offset) : 0
        offset += 4
        let authCode: UInt32 = payload.count >= offset + 4 ? payload.readUInt32LE(at: offset) : 0
        offset += 4
        
        // Path hashes (pathLen bytes)
        let pathHashes = payload.count >= offset + pathLen ? Array(payload[offset..<offset+pathLen]) : []
        offset += pathLen
        
        // Path SNRs (pathLen + 1 bytes, each = SNR * 4)
        let snrCount = pathLen + 1
        let pathSNRs = payload.count >= offset + snrCount ? Array(payload[offset..<offset+snrCount]) : []
        
        // Cancel trace timeout
        traceTimeoutTask?.cancel()
        
        Task { @MainActor in
            self.isActivityInProgress = false
            self.displayTraceResult(pathHashes: pathHashes, pathSNRs: pathSNRs)
        }
    }
```

Display as a visual trace:
```swift
func displayTraceResult(pathHashes: [UInt8], pathSNRs: [UInt8]) {
    var traceSteps: [String] = ["You"]
    for (i, hash) in pathHashes.enumerated() {
        let snr = i < pathSNRs.count ? Double(Int8(bitPattern: pathSNRs[i])) / 4.0 : 0
        traceSteps.append(String(format: "%02X (%.1f dB)", hash, snr))
    }
    // Last SNR is the destination
    if let lastSNR = pathSNRs.last {
        let snr = Double(Int8(bitPattern: lastSNR)) / 4.0
        traceSteps.append(String(format: "Destination (%.1f dB)", snr))
    }
    traceResultMessage = traceSteps.joined(separator: " → ")
}
```

### E3: PUSH_CODE_TELEMETRY_RESPONSE (0x8B)

Completes the "Request Telemetry" feature.

```swift
case 0x8B: // PUSH_CODE_TELEMETRY_RESPONSE
    if payload.count >= 7 {
        let reserved = payload[0]
        let pubkeyPrefix = payload[1..<7]
        let lppData = payload.suffix(from: 7)
        
        // Cancel telemetry timeout
        telemetryTimeoutTask?.cancel()
        
        Task { @MainActor in
            self.isActivityInProgress = false
            self.parseCayenneLPP(data: lppData)
        }
    }
```

Cayenne LPP parser (basic implementation):
```swift
func parseCayenneLPP(data: Data) {
    var results: [String] = []
    var i = 0
    while i < data.count - 1 {
        let channel = data[i]; i += 1
        let type = data[i]; i += 1
        
        switch type {
        case 0x67: // Temperature (2 bytes, signed, 0.1°C)
            if i + 2 <= data.count {
                let raw = Int16(data[i]) << 8 | Int16(data[i+1])
                let temp = Double(raw) / 10.0
                results.append(String(format: "Temperature: %.1f°C / %.1f°F", temp, temp * 9/5 + 32))
                i += 2
            }
        case 0x68: // Humidity (1 byte, 0.5%)
            if i + 1 <= data.count {
                let humidity = Double(data[i]) / 2.0
                results.append(String(format: "Humidity: %.1f%%", humidity))
                i += 1
            }
        case 0x73: // Barometric pressure (2 bytes, 0.1 hPa)
            if i + 2 <= data.count {
                let raw = UInt16(data[i]) << 8 | UInt16(data[i+1])
                let pressure = Double(raw) / 10.0
                results.append(String(format: "Pressure: %.1f hPa", pressure))
                i += 2
            }
        case 0x88: // GPS (9 bytes)
            if i + 9 <= data.count {
                let lat = Double(Int32(data[i]) << 16 | Int32(data[i+1]) << 8 | Int32(data[i+2])) / 10000.0
                let lon = Double(Int32(data[i+3]) << 16 | Int32(data[i+4]) << 8 | Int32(data[i+5])) / 10000.0
                let alt = Double(Int32(data[i+6]) << 16 | Int32(data[i+7]) << 8 | Int32(data[i+8])) / 100.0
                results.append(String(format: "GPS: %.4f, %.4f (%.0fm)", lat, lon, alt))
                i += 9
            }
        case 0x02: // Analog input (2 bytes, 0.01)
            if i + 2 <= data.count {
                let raw = UInt16(data[i]) << 8 | UInt16(data[i+1])
                let voltage = Double(raw) / 100.0
                results.append(String(format: "Voltage: %.2fV", voltage))
                i += 2
            }
        default:
            results.append(String(format: "Unknown sensor type 0x%02X", type))
            break // Can't parse unknown types — stop here
        }
    }
    
    telemetryResultMessage = results.isEmpty ? "No sensor data in response." : results.joined(separator: "\n")
}
```

### E4: PUSH_CODE_CONTACT_DELETED (0x8F) and CONTACTS_FULL (0x90)

These are important for user awareness:

```swift
case 0x8F: // PUSH_CODE_CONTACT_DELETED
    // Contact was evicted from device (storage full, new contact added)
    logger.info("PUSH_CODE_CONTACT_DELETED")
    Task { @MainActor in
        // Remove from local contact list
        // Optionally show a notification
        self.showToast("A contact was removed from the device to make room for new contacts.")
        self.requestIncrementalContactSync()
    }

case 0x90: // PUSH_CODE_CONTACTS_FULL
    logger.warning("PUSH_CODE_CONTACTS_FULL — contact storage is full")
    Task { @MainActor in
        self.showToast("Contact storage full. New contacts cannot be added until space is freed.")
    }
```

### E5: PUSH_CODE_NEW_ADVERT (0x8A)

When manual_add_contacts is enabled, new contacts go to a "pending" list instead of being auto-added:

```swift
case 0x8A: // PUSH_CODE_NEW_ADVERT
    // Same format as RESP_CODE_CONTACT — parse as a contact
    if let newContact = parseContactPayload(payload) {
        logger.info("PUSH_CODE_NEW_ADVERT: \(newContact.advName)")
        Task { @MainActor in
            self.pendingNewContacts.append(newContact)
            self.showToast("New node discovered: \(newContact.advName)")
        }
        // Also feed into discover results if discover is active
        addToDiscoverResults(newContact)
    }
```

Commit: "feat: push handlers — status, trace, telemetry, contact deleted, contacts full, new advert"

---

## SECTION F: MESSAGE POLISH

### F1: Message timestamps

Show relative timestamps on messages. Group messages by day.

```swift
// Date separator between message groups
struct DateSeparator: View {
    let date: Date
    
    var body: some View {
        HStack {
            VStack { Divider() }
            Text(formattedDate(date))
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
            VStack { Divider() }
        }
        .padding(.vertical, 4)
    }
    
    func formattedDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
}

// On each message bubble, show time
Text(message.timestamp, style: .time)
    .font(.caption2)
    .foregroundColor(.tertiary)
```

### F2: Message delivery status icons

Expand the existing Sent ✓ / Delivered ✓✓ to cover all states:

```swift
func deliveryStatusView(for message: Message) -> some View {
    Group {
        switch message.deliveryStatus {
        case .pending:
            Image(systemName: "clock")
                .foregroundColor(.secondary)
        case .sent:
            Image(systemName: "checkmark")
                .foregroundColor(.secondary)
        case .delivered:
            HStack(spacing: -4) {
                Image(systemName: "checkmark")
                Image(systemName: "checkmark")
            }
            .foregroundColor(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(.red)
        }
    }
    .font(.caption2)
}
```

### F3: Retry failed messages

When a message fails (timeout with no ACK), let the user tap to retry:

```swift
if message.deliveryStatus == .failed {
    Button(action: { viewModel.retryMessage(message) }) {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(.red)
            Text("Tap to retry")
                .font(.caption2)
                .foregroundColor(.red)
        }
    }
}
```

### F4: Character count for DMs

MeshCore DMs are limited to ~160 characters. Show a counter:

```swift
// In the message input area
HStack {
    TextField("Message", text: $messageText)
    
    if !messageText.isEmpty {
        Text("\(messageText.count)/160")
            .font(.caption2)
            .foregroundColor(messageText.count > 160 ? .red : .secondary)
    }
    
    Button(action: { sendMessage() }) {
        Image(systemName: "arrow.up.circle.fill")
    }
    .disabled(messageText.isEmpty || messageText.count > 160)
}
```

### F5: Keyboard handling (iOS)

Ensure the chat input stays above the keyboard on iOS:

```swift
// The ScrollView + TextField combination in SwiftUI should handle this automatically
// with .scrollDismissesKeyboard(.interactively) on the message list
ScrollView {
    LazyVStack { /* messages */ }
}
.scrollDismissesKeyboard(.interactively)  // dismiss keyboard on scroll

// Send on Return key
TextField("Message", text: $messageText)
    .onSubmit { sendMessage() }
```

Commit: "feat: message polish — timestamps, delivery icons, retry, character count, keyboard"

---

## SECTION G: iOS DEPLOYMENT AND BACKGROUND BLE

This is the reason the entire project exists. Background BLE on iOS.

### G1: Info.plist for iOS

Make sure the iOS target's Info.plist (or the Xcode project settings under Signing & Capabilities) includes:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>bluetooth-central</string>
</array>

<key>NSBluetoothAlwaysUsageDescription</key>
<string>MeshCore needs Bluetooth to communicate with your LoRa radio device for off-grid mesh messaging.</string>
```

If using Xcode's Signing & Capabilities UI:
1. Select the iOS target
2. Click "+ Capability"
3. Add "Background Modes"
4. Check "Uses Bluetooth LE accessories"

### G2: CBCentralManager with state restoration

Verify the BLEManager initializes CBCentralManager with a restore identifier:

```swift
centralManager = CBCentralManager(
    delegate: self,
    queue: DispatchQueue(label: "com.meshcore.ble", qos: .userInitiated),
    options: [
        CBCentralManagerOptionRestoreIdentifierKey: "com.meshcore.centralmanager"
    ]
)
```

### G3: willRestoreState delegate

This is called when iOS relaunches the app after it was terminated while a BLE connection was active:

```swift
func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
    if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
        for peripheral in peripherals {
            peripheral.delegate = self
            self.connectedPeripheral = peripheral
            // Re-discover services and re-subscribe to NUS TX characteristic
            peripheral.discoverServices([CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")])
        }
    }
}
```

### G4: Auto-reconnect on background disconnect

The didDisconnectPeripheral handler should always attempt reconnection, even in the background. CoreBluetooth queues the reconnect request and executes it when the device is available:

```swift
func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    // ALWAYS request reconnection — CoreBluetooth handles this even in background
    central.connect(peripheral, options: nil)
    
    Task { @MainActor in
        self.connectionState = .reconnecting
    }
}
```

This is different from the macOS behavior where we do 3 retries then give up. On iOS, we always reconnect because CoreBluetooth manages the queue efficiently in the background.

### G5: Local notifications for background messages

When a message arrives while the app is in the background, fire a local notification:

```swift
import UserNotifications

func requestNotificationPermission() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
        if granted {
            logger.info("Notification permission granted")
        }
    }
}

func sendLocalNotification(from senderName: String, message: String) {
    // Only send if app is in background
    guard UIApplication.shared.applicationState != .active else { return }
    
    let content = UNMutableNotificationContent()
    content.title = senderName
    content.body = message
    content.sound = .default
    
    let request = UNNotificationRequest(
        identifier: UUID().uuidString,
        content: content,
        trigger: nil  // deliver immediately
    )
    
    UNUserNotificationCenter.current().add(request)
}
```

Call `requestNotificationPermission()` on first launch. Call `sendLocalNotification()` from the message handler when a new message arrives.

**Platform guard** — this code is iOS-only. Wrap it:
```swift
#if os(iOS)
// ... notification code
#endif
```

### G6: NavigationSplitView iPhone layout

Verify the app uses NavigationSplitView which automatically collapses to a stack on iPhone:

```swift
NavigationSplitView {
    // Sidebar: contact list + channels
    SidebarView()
} detail: {
    // Detail: chat view or settings
    if let contact = selectedContact {
        ChatView(contact: contact)
    } else {
        NoSelectionView()
    }
}
```

On iPhone, this becomes a push navigation (sidebar → detail). On iPad and Mac, it's a split view. Make sure tapping a contact pushes to the chat correctly and the back button works.

### G7: iOS build verification

```bash
xcodebuild clean build -scheme MeshCoreApple -destination 'generic/platform=iOS'
```

Fix any iOS-specific build errors. Common issues:
- `NSPasteboard` (macOS) vs `UIPasteboard` (iOS) — use `#if os(macOS)` / `#if os(iOS)`
- `NSApplication` vs `UIApplication`
- Any macOS-only APIs used without platform checks

Commit: "feat: iOS deployment — background BLE, state restoration, local notifications, iPhone layout"

---

## SECTION H: TESTFLIGHT PREREQUISITES

These are the items that must exist before you can upload to TestFlight. Claude Code can generate some of these, but others are manual steps you'll do in Xcode and App Store Connect.

### H1: Privacy policy

Create a simple privacy policy page. This can be a markdown file that you host on GitHub Pages:

```markdown
# MeshCore Privacy Policy

**Last updated:** March 2026

MeshCore is an off-grid mesh networking app. It connects to your personal MeshCore radio via Bluetooth.

## Data Collection
MeshCore does not collect, store, or transmit any personal data to external servers. All communication happens directly between your device and your MeshCore radio over Bluetooth, and between radios over LoRa (a local radio protocol).

## Data Stored on Device
- Message history (stored locally on your device only)
- Radio connection credentials (stored in Apple Keychain, encrypted, never transmitted)
- App preferences (stored locally on your device only)

## Network Communication
MeshCore does not connect to the internet. All messaging occurs over LoRa radio, which is a local, off-grid protocol. No data passes through any server.

## Third-Party Services
MeshCore does not use any third-party analytics, advertising, or tracking services.

## Contact
For questions about this privacy policy, contact: [your email]
```

Save this as `PRIVACY_POLICY.md` in the project root. You can host it on GitHub Pages or create a simple HTML version.

### H2: App description for App Store Connect

```
MeshCore — Off-Grid Mesh Messaging

Send encrypted text messages without cellular service, WiFi, or internet using MeshCore LoRa radios. MeshCore creates a decentralized mesh network where messages hop between radios to reach their destination — even miles away.

Features:
• Direct encrypted messaging between MeshCore devices
• Group channels (public and private)
• Room server chat — messages persist even when you're offline
• Remote management of repeaters and room servers over LoRa
• Background Bluetooth — stay connected even when the app is in the background
• Favourite contacts with sync to your radio
• Saved login credentials for quick access to infrastructure
• Full dark mode support

Requires a MeshCore-compatible LoRa radio (Heltec Mesh Pocket, Heltec V3, RAK WisMesh, T-Beam, T-Deck, and more). Flash MeshCore firmware at flasher.meshcore.co.uk.

MeshCore is open source. Learn more at github.com/meshcore-dev/MeshCore.
```

### H3: "What to Test" beta notes

```
Welcome to the MeshCore Apple beta!

Please test:
1. Connect to your MeshCore radio via Bluetooth
2. Send and receive direct messages
3. Join channels and send channel messages
4. Star favourite contacts (verify they persist after reconnect)
5. Login to room servers and repeaters (test saved credentials)
6. Background the app for 20+ minutes, then check if messages still arrive
7. Try light and dark themes (Settings → Appearance)

Known limitations:
- watchOS app not yet available
- Map view not yet implemented
- Some advanced protocol features are still in progress

Please report bugs via TestFlight feedback or email [your email].
```

### H4: Export compliance

Create a file to remind yourself of the declaration:

MeshCore uses end-to-end encryption, but the encryption is implemented in the radio firmware (C++), not in the app itself. The app transmits pre-encrypted binary frames over BLE. For the App Store export compliance questionnaire:
- Does your app use encryption? → Yes
- Is your app exempt from export compliance documentation? → Likely Yes (the app itself doesn't implement encryption — it passes through encrypted payloads from the firmware)
- If asked for more detail: The app uses Apple's standard Bluetooth APIs. Encryption is performed by the connected hardware device's firmware, not by the app.

### H5: Build number and version

Make sure the project has proper versioning:
- Marketing Version (CFBundleShortVersionString): `1.0.0`
- Build Number (CFBundleVersion): `1` (increment with each TestFlight upload)

Commit: "chore: TestFlight prerequisites — privacy policy, app description, export compliance notes"

---

## FINAL: Complete build verification

After all sections are complete:

1. **macOS build:** `xcodebuild clean build -scheme MeshCoreApple -destination 'platform=macOS'`
2. **iOS build:** `xcodebuild clean build -scheme MeshCoreApple -destination 'generic/platform=iOS'`
3. Verify zero warnings on both platforms

### macOS field test:
- [ ] Theme switcher works (System / Light / Dark)
- [ ] All colors correct in both light and dark mode
- [ ] Empty states show when: no connection, no contacts, no messages
- [ ] Settings sections have help text footers
- [ ] Destructive actions (reboot, factory reset) have confirmation dialogs
- [ ] Discover button works — falls back to flood advertisement gracefully
- [ ] Status request → response displayed (if target device supports it)
- [ ] Trace route → visual trace displayed (for multi-hop contacts)

### iOS deployment test:
- [ ] Deploy to iPhone via Xcode (USB, personal team signing)
- [ ] Trust developer certificate: Settings → General → VPN & Device Management
- [ ] Connect to Mesh Pocket via Bluetooth
- [ ] Send and receive messages
- [ ] Background app for 20+ minutes → receive message → local notification fires
- [ ] Lock phone → receive message → notification on lock screen
- [ ] NavigationSplitView works as stack on iPhone (push/pop)
- [ ] Message input stays above keyboard
- [ ] Character count shows on message input

### Message polish:
- [ ] Date separators between message groups (Today, Yesterday, dates)
- [ ] Timestamps on each message
- [ ] Pending (clock) → Sent (✓) → Delivered (✓✓) status flow
- [ ] Failed messages show red ! and "Tap to retry"
- [ ] Retry actually resends the message

### TestFlight readiness:
- [ ] Privacy policy file exists in project
- [ ] App description drafted
- [ ] Beta test notes drafted
- [ ] Version is 1.0.0, build 1
- [ ] App icon is 1024x1024 (no Xcode warnings)

Commit: "chore: Phase 3 complete — theme, iOS deployment, push handlers, TestFlight ready"
Push to GitHub.

---

## WHAT'S LEFT AFTER PHASE 3 (for reference — NOT part of this work order)

After Phase 3, the app is publicly distributable via TestFlight. The remaining items are enhancements, not blockers:

- **Manual steps you do yourself:** Apple Developer enrollment ($99), App Store Connect setup, archive + upload, TestFlight invite testers
- **Phase 4 (future):** Map view, watchOS app, nicknames/notes, contact groups, SwiftData migration, v1.14 CLI commands in remote management, channel create/join, region/scope management
- **Phase 5 (future):** USB serial + WiFi connection support, Siri Shortcuts, iCloud sync, deep links, onboarding flow, Home Assistant awareness
