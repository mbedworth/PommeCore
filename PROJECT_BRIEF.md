# MeshCore Apple Client — Claude Code Project Brief

## Mission
Build a native SwiftUI multiplatform MeshCore client app for all Apple platforms:
- **iOS / iPadOS** (primary — full messaging, maps, device management)
- **macOS** (desktop experience, menu bar presence)
- **watchOS** (lightweight messaging, complications, background BLE alerts)

The goal is to make MeshCore a legitimate competitor to Meshtastic on the Apple ecosystem by providing a reliable, native experience with proper background BLE connectivity — something the existing Flutter-based MeshCore apps have failed to deliver.

## Project Name
`MeshCoreApple` (working title — open to suggestions)

## License
MIT (matching MeshCore firmware license)

## Architecture Overview

### Three-Layer Design

```
┌─────────────────────────────────────────────┐
│           Platform Targets (SwiftUI)         │
│  ┌─────────┐ ┌─────────┐ ┌───────────────┐  │
│  │   iOS   │ │  macOS  │ │   watchOS     │  │
│  │  iPadOS │ │         │ │               │  │
│  └────┬────┘ └────┬────┘ └──────┬────────┘  │
│       │           │             │            │
│  ┌────┴───────────┴─────────────┴────────┐   │
│  │     Shared SwiftUI Views & ViewModels │   │
│  └───────────────────┬───────────────────┘   │
│                      │                       │
│  ┌───────────────────┴───────────────────┐   │
│  │    MeshCoreKit (Swift Package)        │   │
│  │  ┌─────────────┐ ┌─────────────────┐  │   │
│  │  │  BLEManager │ │ MeshCoreProtocol│  │   │
│  │  │(CoreBluetooth)│ │ (encode/decode)│  │   │
│  │  └─────────────┘ └─────────────────┘  │   │
│  │  ┌─────────────┐ ┌─────────────────┐  │   │
│  │  │  Crypto     │ │  ContactStore   │  │   │
│  │  └─────────────┘ └─────────────────┘  │   │
│  └───────────────────────────────────────┘   │
└─────────────────────────────────────────────┘
```

**Layer 1 — MeshCoreKit (Swift Package):**
Pure Swift, no UI dependencies. Contains:
- `BLEManager`: CoreBluetooth CBCentralManager wrapper with background mode support, state restoration, auto-reconnect
- `MeshCoreProtocol`: Binary frame encoding/decoding for the MeshCore protocol
- `MeshCoreCrypto`: Key exchange and message encryption (Curve25519 + AES)
- `ContactStore`: Contact management, message storage
- `Models`: Contact, Message, Channel, DeviceInfo data types

**Layer 2 — Shared Views:**
SwiftUI views shared across iOS, iPadOS, and macOS (with `#if os()` for platform-specific adaptations):
- ContactListView, ChatView, ChannelView, MapView, SettingsView, DeviceScannerView

**Layer 3 — Platform Targets:**
- iOS/iPadOS: Full experience with NavigationSplitView, maps, repeater hub
- macOS: Desktop layout, potential menu bar status item
- watchOS: Minimal — contact list, chat, connection status complication

---

## MeshCore BLE Protocol Details

### Nordic UART Service (NUS)
- **Service UUID**: `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`
- **RX Characteristic** (write to device): `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`
- **TX Characteristic** (notify from device): `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`

### Device Discovery
Devices advertise with BLE name prefix: `MeshCore-`

### Frame Structure
Messages are binary frames. Reference implementations:
- JavaScript: https://github.com/liamcottle/meshcore.js
- Dart: https://github.com/zjs81/meshcore-open (lib/connector/meshcore_protocol.dart)
- C++ firmware: https://github.com/meshcore-dev/MeshCore

### Key Protocol Commands (from meshcore.js / meshcore_protocol.dart)
```
Command bytes (first byte of frame):
0x01 = APPSTART (initialize connection)
0x02 = SEND_TXT_MSG (send text message)
0x03 = SEND_CHANNEL_MSG (send channel message)  
0x04 = GET_CONTACTS (request contact list)
0x05 = GET_MESSAGES (request message history)
0x06 = GET_DEVICE_INFO (request device info — name, firmware, battery, etc.)
0x07 = SET_DEVICE_NAME (set display name)
0x08 = SEND_SELF_ADVERTISE (advertise on mesh)
0x09 = SET_RADIO_PARAMS (configure LoRa: freq, BW, SF, power)
0x0A = GET_RADIO_PARAMS
0x0B = REBOOT_DEVICE
... (see protocol reference for full list)
```

### Response Parsing
Responses come as binary frames on the TX characteristic notification.
First byte indicates response type, remaining bytes are payload.

---

## Critical iOS Background BLE Requirements

This is THE most important technical aspect of the entire project. The existing Flutter apps fail here.

### Info.plist Requirements
```xml
<key>UIBackgroundModes</key>
<array>
    <string>bluetooth-central</string>
</array>

<key>NSBluetoothAlwaysUsageDescription</key>
<string>MeshCore needs Bluetooth to communicate with your LoRa radio device.</string>
```

### CBCentralManager Initialization
```swift
// MUST provide a restore identifier for state preservation
centralManager = CBCentralManager(
    delegate: self,
    queue: DispatchQueue(label: "com.meshcore.ble", qos: .userInitiated),
    options: [
        CBCentralManagerOptionRestoreIdentifierKey: "com.meshcore.centralmanager"
    ]
)
```

### Required Delegate Methods
```swift
// State restoration — called when iOS relaunches app after termination
func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
    if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
        for peripheral in peripherals {
            // Re-set delegate, re-discover services, re-subscribe to TX notifications
            peripheral.delegate = self
            self.connectedPeripheral = peripheral
            // Re-subscribe to NUS TX characteristic
        }
    }
}

// Auto-reconnect on disconnect
func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    // Immediately request reconnection — CoreBluetooth will queue this
    // and execute when peripheral is available, even while app is suspended
    central.connect(peripheral, options: nil)
}
```

### watchOS BLE Background (Series 6+)
```xml
<!-- watchOS Info.plist -->
<key>UIBackgroundModes</key>
<array>
    <string>bluetooth-central</string>
</array>
```
watchOS supports background BLE characteristic monitoring — the watch can receive mesh notifications with the screen off. Limited to ~5 background runtime events per 24-hour rolling window (resets on user interaction).

---

## Step 1: Project Scaffolding

Please create the following structure:

```
~/Developer/MeshCoreApple/
├── MeshCoreApple.xcodeproj/     (or .xcworkspace)
├── Packages/
│   └── MeshCoreKit/
│       ├── Package.swift
│       └── Sources/
│           └── MeshCoreKit/
│               ├── BLE/
│               │   ├── BLEManager.swift
│               │   ├── BLEConstants.swift
│               │   └── BLEBackgroundHandler.swift
│               ├── Protocol/
│               │   ├── MeshCoreProtocol.swift
│               │   ├── MeshCoreCommands.swift
│               │   └── FrameParser.swift
│               ├── Models/
│               │   ├── Contact.swift
│               │   ├── Message.swift
│               │   ├── Channel.swift
│               │   └── DeviceInfo.swift
│               └── Crypto/
│                   └── MeshCoreCrypto.swift
├── Shared/
│   ├── Views/
│   │   ├── ContactListView.swift
│   │   ├── ChatView.swift
│   │   ├── DeviceScannerView.swift
│   │   └── SettingsView.swift
│   ├── ViewModels/
│   │   ├── MeshCoreViewModel.swift
│   │   └── ChatViewModel.swift
│   └── App/
│       └── MeshCoreApp.swift
├── iOS/
│   └── Info.plist
├── macOS/
│   └── Info.plist
└── watchOS/
    ├── Info.plist
    └── Views/
        └── WatchChatView.swift
```

Start with the Swift Package (MeshCoreKit) and the BLEManager — that's the foundation everything else builds on. Get BLE scanning, connecting to a MeshCore- prefixed device, discovering NUS service/characteristics, and subscribing to TX notifications working first. Include proper background mode support from the start.

Then scaffold the Xcode multiplatform project that imports MeshCoreKit as a local package dependency, with targets for iOS, macOS, and watchOS.

## Step 2: Protocol Implementation

After scaffolding, implement the core protocol commands:
1. APPSTART (connection handshake)
2. GET_DEVICE_INFO (verify we can talk to the device)
3. GET_CONTACTS (pull contact list)
4. SEND_TXT_MSG / receive text messages
5. SEND_SELF_ADVERTISE (advertise on mesh)

## Step 3: UI

Build minimal but functional SwiftUI views:
1. Device scanner (list nearby MeshCore- BLE devices, tap to connect)
2. Contact list (populated from GET_CONTACTS)
3. Chat view (send/receive messages)
4. Connection status indicator

## Reference Repositories
- MeshCore firmware (C++, MIT): https://github.com/meshcore-dev/MeshCore
- meshcore.js (JavaScript protocol, MIT): https://github.com/liamcottle/meshcore.js  
- MeshCore Open (Flutter/Dart, MIT): https://github.com/zjs81/meshcore-open
- Meshtastic Apple (Swift, GPL3 — study architecture only, do NOT copy code): https://github.com/meshtastic/Meshtastic-Apple

## Important Notes
- All code must be original — do not copy from GPL-licensed Meshtastic
- Use Swift concurrency (async/await) where appropriate
- Use SwiftData or Core Data for local persistence (SwiftData preferred for simplicity)
- Minimum deployment targets: iOS 16, macOS 13, watchOS 9
- Use Xcode's Multiplatform App template as the starting point
