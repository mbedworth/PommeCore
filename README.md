# MeshCoreApple

Native SwiftUI client for [MeshCore](https://github.com/rpp0/MeshCore) LoRa mesh radio devices. Communicates via BLE using the MeshCore Companion Radio Protocol.

## Platforms

- iOS 16+
- macOS 13+
- watchOS 9+

## Features

- **BLE connectivity** — CoreBluetooth with Nordic UART Service (NUS), background mode, state restoration, auto-reconnect
- **Direct messaging** — Send/receive with delivery confirmation (sending → sent → delivered with round-trip time)
- **Channel messaging** — Public channel broadcast with sender attribution
- **Contact management** — Auto-sync from device, incremental updates, unread badges
- **Device settings** — Radio configuration, identity/advertising, privacy, tuning parameters, statistics
- **Remote management** — Login to repeaters and room servers, full CLI over LoRa, form-based settings UI
- **Message persistence** — JSON file-based storage (iOS 16 compatible)
- **Background notifications** — Local notifications for incoming messages when backgrounded
- **Haptic feedback** — Tactile confirmation on message send (iOS/watchOS)

## Architecture

```
MeshCoreApple/
├── Packages/MeshCoreKit/       # Swift Package — BLE, protocol, models
│   └── Sources/MeshCoreKit/
│       ├── BLE/                # BLEManager, constants, background handler
│       ├── Protocol/           # Frame parser, command builder, command codes
│       ├── Models/             # Contact, Message, DeviceConfig, MessageStore
│       └── Crypto/             # MeshCore crypto utilities
├── Shared/                     # Multiplatform app code
│   ├── App/                    # MeshCoreApp entry point, Theme
│   ├── ViewModels/             # MeshCoreViewModel (central state)
│   └── Views/                  # ContactList, Chat, Settings, RemoteManagement, Scanner
├── iOS/                        # iOS target resources
├── macOS/                      # macOS target resources
└── watchOS/                    # watchOS target and views
```

## Protocol

Implements the MeshCore Companion Radio Protocol over BLE Nordic UART Service:
- **Service UUID:** `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`
- **TX Characteristic:** `6E400002` (write)
- **RX Characteristic:** `6E400003` (notify)

Binary frame encoding with command codes, response codes, and push notifications (0x80-0x8F range).

## Building

Open `MeshCoreApple.xcodeproj` in Xcode 15+ and select the desired target (iOS, macOS, or watchOS).
