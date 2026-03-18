# MeshCoreApple — Phase 2 Work Order
## Channels, Toolbar, and Live Push Handlers
## For Claude Code — Execute in order, commit after each section

**Project:** ~/Developer/MeshCoreApple
**Date:** March 14, 2026
**Goal:** Fix channel display bugs, clean up toolbar behavior, and implement the two push handlers that make the contact list update in real-time. After this phase the app should feel responsive and correct for field testing.

---

## SECTION A: CHANNEL DISPLAY FIXES

All five of these are in the sidebar channel list and channel chat views. Fix them together as a single coherent pass.

### A1: Double hash bug (##testing → #testing)

Find where channel names are displayed in the sidebar and chat header. The channel name stored on the device already includes the "#" prefix (e.g., "#testing"), but the display code adds another one.

**Search for** any code that prepends "#" to a channel name and fix it:

```swift
// WRONG — produces "##testing"
Text("#\(channel.name)")

// RIGHT — display as-is, the name already has "#" if it's a hashtag channel
Text(channel.name)
```

Do a project-wide search for `"#\(` and `"#" +` to catch all instances where a hash is being prepended to channel names.

### A2: Private channel incorrectly shows "#"

Channels where the name does NOT start with "#" are private channels (e.g., "Casa Palms Channel"). These should show a lock icon, not a hash icon, and no "#" prefix.

### A3: Fix icon assignment logic

Replace whatever icon logic exists with this correct version:

```swift
func iconForChannel(_ channel: MeshChannel) -> String {
    if channel.index == 0 {
        return "megaphone.fill"       // Public channel — always index 0
    } else if channel.name.hasPrefix("#") {
        return "number"               // Hashtag/community channels
    } else {
        return "lock.fill"            // Private/encrypted channels
    }
}
```

Search the codebase for everywhere a channel icon is determined and replace with this function (or call this function). Make sure the public channel (index 0) ALWAYS gets the megaphone regardless of its name.

### A4: Public channel placement

The Public Channel (index 0) should appear as the first item inside the "Channels" section in the sidebar, not floating above it. If it's currently rendered separately above the section header, move it inside. It should be visually consistent with the other channels but distinguished by the megaphone icon.

```swift
Section("Channels") {
    // Public channel first (index 0)
    if let publicChannel = channels.first(where: { $0.index == 0 }) {
        ChannelRow(channel: publicChannel)
    }
    // Then all other channels sorted by index
    ForEach(channels.filter { $0.index != 0 }.sorted(by: { $0.index < $1.index })) { channel in
        ChannelRow(channel: channel)
    }
}
```

### A5: Channel messaging with correct index

Find where CMD_SEND_CHANNEL_TXT_MSG (0x03) is built. The channel_idx byte may be hardcoded to 0. Fix it to use the actual channel's index:

```swift
func sendChannelMessage(text: String, channel: MeshChannel) {
    // Build frame: code(0x03) + txt_type(1 byte) + channel_idx(1 byte) + timestamp(4 bytes) + text
    var frame = Data()
    frame.append(0x03)                              // CMD_SEND_CHANNEL_TXT_MSG
    frame.append(0x00)                              // txt_type = plain text
    frame.append(UInt8(channel.index))              // USE THE ACTUAL CHANNEL INDEX
    frame.append(contentsOf: currentEpochBytes())   // timestamp
    frame.append(text.data(using: .utf8) ?? Data()) // message text
    sendFrame(frame)
}
```

Search for `0x03` or `CMD_SEND_CHANNEL` or the function name that builds channel message frames and verify the channel index is coming from the selected channel, not hardcoded.

Commit: "fix: channel display — correct icons, no double hash, proper index on send"

---

## SECTION B: TOOLBAR ICON BEHAVIOR AND TOOLTIPS

### B1: Verify all toolbar icons have distinct, correct functions

Audit the toolbar and verify each icon does what it should. The correct mapping is:

| Icon | Symbol | Action | When visible |
|------|--------|--------|--------------|
| Broadcast | `antenna.radiowaves.left.and.right` | Send self-advertisement (CMD_SEND_SELF_ADVERT, code 0x07) | Always (disabled when not connected) |
| Settings | `gearshape` | Open local device settings | Always |
| Remote Management | `wrench.and.screwdriver` | Open remote management for logged-in device | Only when logged into a repeater/room server |
| Refresh | `arrow.clockwise` | Re-sync contacts and channels from device | When connected |

If a "Discover" button exists:
| Discover | `binoculars` or `dot.radiowaves.right` | Discover nearby nodes (flood advert fallback) | When connected |

**The broadcast icon must NOT disconnect.** This was fixed in Phase 1, but double-check it's still correct.

If any icons are missing, ambiguous, or doing the wrong thing, fix them.

### B2: Add tooltips to all toolbar icons (macOS)

Add `.help()` modifier to every toolbar button:

```swift
Button(action: { viewModel.sendSelfAdvertisement() }) {
    Image(systemName: "antenna.radiowaves.left.and.right")
}
.help("Send Advertisement — announce your presence on the mesh")
.disabled(!viewModel.isConnected)

Button(action: { showSettings = true }) {
    Image(systemName: "gearshape")
}
.help("Device Settings — configure your local radio")

// Only show when logged into a remote device
if viewModel.hasActiveManagementSession {
    Button(action: { showRemoteManagement = true }) {
        Image(systemName: "wrench.and.screwdriver")
    }
    .help("Remote Management — configure \(viewModel.activeManagementDeviceName ?? "remote device")")
}

Button(action: { viewModel.refreshAll() }) {
    Image(systemName: "arrow.clockwise")
}
.help("Refresh — re-sync contacts, channels, and settings from device")
.disabled(!viewModel.isConnected)
```

### B3: Add iOS accessibility labels

For each toolbar button, also add accessibility support:

```swift
.accessibilityLabel("Send Advertisement")
.accessibilityHint("Announce your presence on the mesh network")
```

Commit: "fix: toolbar icons — correct actions, tooltips, accessibility labels"

---

## SECTION C: HIGH-PRIORITY PUSH HANDLERS (0x80 and 0x81)

These two push handlers are what make the app feel alive. Without them, the contact list only updates when you manually refresh or reconnect. With them, the app automatically picks up new contacts, updated paths, and signal changes as they happen over the mesh.

### C1: PUSH_CODE_ADVERT (0x80) — Known contact sent advertisement

**When received:** A contact already in your contact list has sent an advertisement. This means their path, signal, or status may have changed.

**Frame format:** `code(0x80) + pub_key(32 bytes)`

**Action:** Trigger an incremental contact sync — re-fetch the contact list with the 'since' parameter so we only get contacts that changed.

```swift
case 0x80: // PUSH_CODE_ADVERT
    if payload.count >= 32 {
        let pubkey = payload.prefix(32)
        logger.info("PUSH_CODE_ADVERT: contact \(pubkey.hexPrefix) sent advertisement")
        
        // Trigger incremental contact sync
        // Use lastContactSyncMod so we only get updated contacts
        sendGetContacts(since: lastContactSyncMod)
    }
```

**Important:** This MUST use the atomic swap pattern from Phase 1 (Section C). The contact list should update smoothly without flickering or disappearing.

### C2: PUSH_CODE_PATH_UPDATED (0x81) — Contact path changed

**When received:** The routing path to a contact has changed (found a better route, lost a route, etc.)

**Frame format:** `code(0x81) + pub_key(32 bytes)`

**Action:** Same as 0x80 — trigger incremental contact sync to get the updated path data.

```swift
case 0x81: // PUSH_CODE_PATH_UPDATED
    if payload.count >= 32 {
        let pubkey = payload.prefix(32)
        logger.info("PUSH_CODE_PATH_UPDATED: path changed for \(pubkey.hexPrefix)")
        
        // Trigger incremental contact sync
        sendGetContacts(since: lastContactSyncMod)
    }
```

### C3: Debounce contact re-syncs

If multiple advertisements come in rapid succession (which happens when you send a flood advert and several nodes respond), don't spam CMD_GET_CONTACTS for each one. Debounce:

```swift
private var contactSyncDebounceTask: Task<Void, Never>?

func requestIncrementalContactSync() {
    contactSyncDebounceTask?.cancel()
    contactSyncDebounceTask = Task {
        // Wait 1 second for rapid-fire events to settle
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if !Task.isCancelled {
            sendGetContacts(since: lastContactSyncMod)
        }
    }
}
```

Then both 0x80 and 0x81 handlers call `requestIncrementalContactSync()` instead of directly sending CMD_GET_CONTACTS.

### C4: Verify the 'since' parameter on CMD_GET_CONTACTS

CMD_GET_CONTACTS (0x04) supports a `lastmod` parameter that tells the device "only give me contacts that changed since this timestamp." Verify the frame builder supports this:

```swift
func sendGetContacts(since lastmod: UInt32 = 0) {
    var frame = Data()
    frame.append(0x04)  // CMD_GET_CONTACTS
    // Append lastmod as little-endian uint32
    var lm = lastmod
    frame.append(Data(bytes: &lm, count: 4))
    sendFrame(frame)
}
```

When `lastmod` is 0, the device sends all contacts (full sync). When it's the value from the last RESP_CODE_END_OF_CONTACTS, only changed contacts are sent (incremental sync).

**Make sure the contact sync handler merges incremental results** — when a partial set of contacts comes back, update those contacts in the existing list rather than replacing the entire list:

```swift
func handleEndOfContacts(lastmod: UInt32) {
    Task { @MainActor in
        if self.pendingContacts.count < self.contacts.count && lastmod > 0 {
            // Incremental update — merge changed contacts into existing list
            for updated in self.pendingContacts {
                if let idx = self.contacts.firstIndex(where: { $0.publicKey == updated.publicKey }) {
                    self.contacts[idx] = updated
                } else {
                    self.contacts.append(updated)
                }
            }
        } else {
            // Full sync — atomic swap
            self.contacts = self.pendingContacts
        }
        self.pendingContacts = []
        self.lastContactSyncMod = lastmod
    }
}
```

### C5: Add the push codes to the frame parser

Find the main frame parser (the big switch statement that handles incoming frames from the radio). Make sure 0x80 and 0x81 have cases. They may currently be falling through to a default "unknown push code" handler or being logged and ignored. Wire them up to the handlers above.

Also while you're in the frame parser, check if there's a catch-all for unrecognized push codes in the 0x80-0xFF range. If not, add one:

```swift
default:
    if code >= 0x80 {
        logger.debug("Unhandled push code 0x\(String(code, radix: 16)): \(payload.count) bytes")
    } else {
        logger.warning("Unknown response code 0x\(String(code, radix: 16)): \(payload.count) bytes")
    }
```

Commit: "feat: live push handlers — 0x80 ADVERT and 0x81 PATH_UPDATED with debounced incremental sync"

---

## SECTION D: QUICK POLISH PASS

While we're in here, knock out a few small items that improve the field testing experience.

### D1: Contact type icons in sidebar

Add visual distinction for contact types in the sidebar list:

```swift
func contactTypeIcon(_ contact: Contact) -> some View {
    let (icon, color): (String, Color) = {
        switch contact.type {
        case 1: return ("person.fill", .blue)                          // Chat companion
        case 2: return ("antenna.radiowaves.left.and.right.fill", .green)  // Repeater
        case 3: return ("building.2.fill", .purple)                    // Room server
        case 4: return ("sensor.fill", .orange)                        // Sensor
        default: return ("questionmark.circle", .gray)                 // Unknown
        }
    }()
    
    Image(systemName: icon)
        .foregroundColor(color)
        .font(.caption)
        .frame(width: 20)
}
```

Use this in the contact list row, before the contact name. If similar icons already exist, unify them to use this function.

### D2: Last advertisement time on contacts

If the contact's `lastAdvert` timestamp is available (it's in the RESP_CODE_CONTACT response), display it as relative time under the contact name:

```swift
func relativeTime(from epoch: UInt32) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(epoch))
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

// In contact row:
VStack(alignment: .leading) {
    HStack {
        Text(contact.displayName)
            .font(.headline)
        if contact.isFavourite {
            Image(systemName: "star.fill")
                .foregroundColor(.yellow)
                .font(.caption2)
        }
    }
    HStack(spacing: 4) {
        // Path info
        if contact.pathLen == 0 {
            Text("direct")
                .font(.caption2)
                .foregroundColor(.green)
        } else if contact.pathLen > 0 && contact.pathLen < 0xFF {
            Text("\(contact.pathLen) hop\(contact.pathLen == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        
        // Last seen
        if contact.lastAdvert > 0 {
            Text("•")
                .font(.caption2)
                .foregroundColor(.tertiary)
            Text(relativeTime(from: contact.lastAdvert))
                .font(.caption2)
                .foregroundColor(.tertiary)
        }
    }
}
```

### D3: Copy message text

Add long-press/right-click on messages to copy text:

```swift
// In message bubble view:
Text(message.text)
    .textSelection(.enabled)  // macOS and iOS 15+ — enables native text selection
    .contextMenu {
        Button(action: {
            #if os(macOS)
            NSPasteboard.general.setString(message.text, forType: .string)
            #else
            UIPasteboard.general.string = message.text
            #endif
        }) {
            Label("Copy", systemImage: "doc.on.doc")
        }
    }
```

### D4: Unread message indicator

Track which contacts have messages that arrived since the user last viewed their chat:

```swift
// In ViewModel:
@Published var unreadCounts: [Data: Int] = [:]  // pubkey -> count

func handleIncomingMessage(from pubkey: Data, ...) {
    // ... existing message handling
    
    // If this contact's chat is NOT currently selected, increment unread
    if selectedContact?.publicKey != pubkey {
        Task { @MainActor in
            self.unreadCounts[pubkey, default: 0] += 1
        }
    }
}

func selectContact(_ contact: Contact) {
    selectedContact = contact
    // Clear unread count when user opens this chat
    unreadCounts[contact.publicKey] = nil
}
```

In the sidebar contact row, show a badge:

```swift
if let count = viewModel.unreadCounts[contact.publicKey], count > 0 {
    Text("\(count)")
        .font(.caption2)
        .fontWeight(.bold)
        .foregroundColor(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.blue, in: Capsule())
}
```

Commit: "polish: contact type icons, last seen times, copy message, unread badges"

---

## SECTION E: SAVED LOGIN CREDENTIALS (Keychain)

Store room server and repeater passwords in Apple Keychain so users don't have to re-enter them every time. Keychain is encrypted at rest, protected by the Secure Enclave, and is the standard iOS/macOS credential store.

### E1: Create a KeychainManager helper

```swift
import Security
import Foundation

struct KeychainManager {
    
    private static let service = "com.mbedworth.meshcore.logins"
    
    /// Save a password for a device identified by its public key
    /// - Parameters:
    ///   - password: The admin or guest password
    ///   - publicKey: The device's 32-byte public key (used as the account identifier)
    ///   - type: "admin" or "guest" — appended to the key to store both separately
    static func savePassword(_ password: String, forDevice publicKey: Data, type: String = "admin") -> Bool {
        let account = publicKey.hexString + "." + type
        
        // Delete any existing entry first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        
        // Add the new entry
        guard let passwordData = password.data(using: .utf8) else { return false }
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: passwordData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    /// Retrieve a saved password for a device
    static func getPassword(forDevice publicKey: Data, type: String = "admin") -> String? {
        let account = publicKey.hexString + "." + type
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    /// Delete a saved password
    static func deletePassword(forDevice publicKey: Data, type: String = "admin") -> Bool {
        let account = publicKey.hexString + "." + type
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
    
    /// Check if a password exists without retrieving it
    static func hasPassword(forDevice publicKey: Data, type: String = "admin") -> Bool {
        return getPassword(forDevice: publicKey, type: type) != nil
    }
}
```

Note: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` means credentials are only available when the device is unlocked, and they do NOT sync to iCloud Keychain. This is correct for mesh infrastructure passwords — they're local to your setup, not something that should float to your iPad.

### E2: Update the login sheet UI

Find the login sheet/view that appears when logging into a room server or repeater. Add:

1. **Auto-fill from Keychain** — when the login sheet opens, check if a saved password exists and pre-fill it:

```swift
struct LoginSheet: View {
    let contact: Contact
    @State private var password: String = ""
    @State private var rememberPassword: Bool = true
    @State private var isLoggingIn: Bool = false
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Login to \(contact.advName)")
                .font(.headline)
            
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
            
            Toggle("Remember Password", isOn: $rememberPassword)
                .font(.subheadline)
            
            if KeychainManager.hasPassword(forDevice: contact.publicKey) {
                Button(role: .destructive, action: {
                    KeychainManager.deletePassword(forDevice: contact.publicKey, type: "admin")
                    KeychainManager.deletePassword(forDevice: contact.publicKey, type: "guest")
                    password = ""
                }) {
                    Label("Forget Saved Password", systemImage: "trash")
                        .font(.caption)
                }
            }
            
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                
                Button("Login") {
                    isLoggingIn = true
                    viewModel.login(to: contact, password: password, remember: rememberPassword)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty || isLoggingIn)
            }
        }
        .padding()
        .onAppear {
            // Auto-fill saved password
            if let saved = KeychainManager.getPassword(forDevice: contact.publicKey, type: "admin") {
                password = saved
            } else if let saved = KeychainManager.getPassword(forDevice: contact.publicKey, type: "guest") {
                password = saved
            }
        }
    }
}
```

2. **The "Remember Password" toggle defaults to ON.** Users who don't want to save can turn it off.

### E3: Save password on successful login

In the login success handler (where PUSH_CODE_LOGIN_SUCCESS 0x85 is processed), save the password if the user opted in:

```swift
func handleLoginSuccess(permissions: UInt8) {
    // ... existing login success handling
    
    // Save password to Keychain if user opted in
    if pendingLoginRememberPassword, let contact = pendingLoginContact, let password = pendingLoginPassword {
        let type = (permissions & 0x03) >= 3 ? "admin" : "guest"
        _ = KeychainManager.savePassword(password, forDevice: contact.publicKey, type: type)
    }
    
    // Clear pending login state
    pendingLoginPassword = nil
    pendingLoginRememberPassword = false
}
```

You'll need to temporarily store the password and remember preference between when the user taps "Login" and when the success response comes back:

```swift
// Add to ViewModel:
private var pendingLoginPassword: String?
private var pendingLoginRememberPassword: Bool = false
private var pendingLoginContact: Contact?

func login(to contact: Contact, password: String, remember: Bool) {
    pendingLoginPassword = password
    pendingLoginRememberPassword = remember
    pendingLoginContact = contact
    sendLoginCommand(to: contact, password: password)
}
```

### E4: Auto-login option (optional but nice)

For devices with a saved password, add an "Auto-login" preference. When tapping a repeater or room server that has a saved credential, instead of showing the login sheet, just log in automatically:

```swift
func onContactTapped(_ contact: Contact) {
    if (contact.type == 2 || contact.type == 3) && !isLoggedIn(to: contact) {
        // Check for saved credentials
        if let savedPassword = KeychainManager.getPassword(forDevice: contact.publicKey) {
            // Auto-login with saved credential
            login(to: contact, password: savedPassword, remember: true)
            return
        }
        // No saved credential — show login sheet
        showLoginSheet = true
    }
    // ... normal contact selection
}
```

Show a brief toast or status message: "Logging in to [device]..." so the user knows what's happening.

If auto-login fails (PUSH_CODE_LOGIN_FAIL 0x86), delete the stale credential from Keychain and show the manual login sheet:

```swift
func handleLoginFail() {
    // Delete stale credential
    if let contact = pendingLoginContact {
        KeychainManager.deletePassword(forDevice: contact.publicKey, type: "admin")
        KeychainManager.deletePassword(forDevice: contact.publicKey, type: "guest")
    }
    
    // Show manual login sheet
    Task { @MainActor in
        self.loginErrorMessage = "Login failed — password may have changed."
        self.showLoginSheet = true
    }
}
```

### E5: Visual indicator for saved credentials

In the sidebar, show a subtle indicator on devices that have saved credentials:

```swift
// In contact row, for type 2 and 3:
if (contact.type == 2 || contact.type == 3) {
    if isLoggedIn(to: contact) {
        Image(systemName: "lock.open.fill")
            .foregroundColor(.green)
            .font(.caption2)
    } else if KeychainManager.hasPassword(forDevice: contact.publicKey) {
        Image(systemName: "key.fill")
            .foregroundColor(.secondary)
            .font(.caption2)
    } else {
        Image(systemName: "lock.fill")
            .foregroundColor(.secondary)
            .font(.caption2)
    }
}
```

This gives three states: locked (no credentials), key (saved password, not logged in yet), unlocked (actively logged in).

Commit: "feat: Keychain credential storage — save/auto-fill/auto-login for repeaters and room servers"

---

## FINAL: Build verification and field test checklist

After all sections are complete:

1. Clean build: `xcodebuild clean build -scheme MeshCoreApple -destination 'platform=macOS'`
2. Verify zero warnings

### Field test checklist — run these with your Mesh Pocket:

**Channels:**
- [ ] Public channel shows megaphone icon, appears first in Channels section
- [ ] Hashtag channels (e.g., #florida) show "#" icon, no double hash in name
- [ ] Private channels (e.g., "Casa Palms Channel") show lock icon, no "#" prefix
- [ ] Send a message in a non-public channel — verify it goes to the correct channel (not public)

**Toolbar:**
- [ ] Broadcast icon sends advertisement, shows confirmation
- [ ] Hovering toolbar icons shows tooltips (macOS)
- [ ] Remote management wrench only visible when logged into a device
- [ ] Refresh button re-syncs contacts and channels

**Live updates:**
- [ ] Send a flood advertisement → watch for new contacts appearing automatically
- [ ] If another node advertises, contact list updates without manual refresh
- [ ] Path changes reflected in contact details without manual refresh
- [ ] Multiple rapid advertisements don't spam the contact list (debounce working)

**Polish:**
- [ ] Contact type icons visible (person/antenna/server/sensor)
- [ ] "direct" or "X hops" shown under contact names
- [ ] Last seen time shown under contact names
- [ ] Favourite contacts (starred) appear at top of list
- [ ] Unread badge appears when a message arrives for a non-selected contact
- [ ] Badge clears when you select that contact's chat
- [ ] Long-press/right-click message → Copy works

**Saved credentials:**
- [ ] Login to room server with "Remember Password" on → password saves
- [ ] Close and reopen login sheet for same device → password auto-fills
- [ ] Disconnect and reconnect → tap room server → auto-login fires with saved credential
- [ ] Change password on device → auto-login fails → stale credential deleted → manual login sheet appears
- [ ] "Forget Saved Password" button clears credential
- [ ] Lock/key/unlocked icons show correctly in sidebar for repeaters and room servers

Commit: "chore: Phase 2 complete — channels, toolbar, live push handlers, polish, keychain credentials"
Push to GitHub.
