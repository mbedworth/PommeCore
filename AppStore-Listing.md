# MeshCore — App Store Listing

## App Name
MeshCore

## Subtitle (30 chars max)
Off-Grid Mesh Messaging

## Description (4000 chars max)

MeshCore is a companion app for MeshCore LoRa radio devices, enabling off-grid text messaging over long-range mesh networks. No cell towers, no internet, no subscriptions — just radio waves.

WHAT IS MESHCORE?

MeshCore is an open-source mesh networking protocol for LoRa radios. Small, affordable radio devices (like the Heltec Mesh Pocket) create a self-healing mesh network that can carry text messages across kilometers of terrain — through forests, over mountains, and into areas with zero cell coverage.

This app connects to your MeshCore radio via Bluetooth and provides a full messaging interface.

KEY FEATURES

- Direct Messages: Send encrypted text messages to specific contacts on the mesh. Messages are acknowledged with delivery confirmation.
- Public Channel: Broadcast messages to everyone on the mesh network, like a group chat for your area.
- Private Channels: Create encrypted group channels with a shared secret key. Only members with the key can read messages.
- Contact Discovery: Automatically discover other MeshCore users nearby. See their name, signal strength, and route through the mesh.
- Repeater Support: Connect through repeater nodes to extend range beyond line-of-sight. Messages automatically find the best path.
- Remote Management: Log into repeaters and room servers to configure settings, view status, and manage the network.
- Trace Route: Visualize the exact path your messages take through the mesh, hop by hop.
- Location Sharing: Optionally share your GPS coordinates on the mesh with configurable privacy radius.
- iCloud Sync: Nicknames, notes, message drafts, and channel configurations sync across your Apple devices.
- Debug Log: Built-in protocol log viewer for troubleshooting without Xcode.

SUPPORTED HARDWARE

Works with any MeshCore-compatible LoRa radio with BLE (Bluetooth Low Energy) support, including:
- Heltec Mesh Pocket
- Heltec V3 with MeshCore companion firmware
- Any ESP32-based device running MeshCore companion firmware

PLATFORMS

- iPhone and iPad via Bluetooth
- Mac via Bluetooth, USB Serial, or WiFi/TCP
- Apple Watch (companion to iPhone)

PRIVACY

MeshCore does not collect any personal data. All communication happens directly between your device and your radio over Bluetooth. Messages travel over the LoRa mesh network, not through any server. Location sharing is optional and can be fuzzed with a configurable privacy radius.

OPEN SOURCE

MeshCore is built on the open-source MeshCore protocol. Learn more at meshcore.co.

## Keywords (100 chars max)
mesh,lora,off-grid,radio,messaging,emergency,outdoor,meshcore,ham,walkie-talkie

## What's New (v1.1.1)

- Fixed channel messaging (protocol version and parser corrections)
- Added in-app debug log viewer for TestFlight diagnostics
- iPad multitasking support (Split View and Slide Over)
- macOS sleep/wake BLE reconnection
- Tappable meshcore:// links in chat messages
- Nickname support in channel messages
- Quick reply from notifications with chat navigation
- Remote admin improvements: GPS advert, loop detection, discover neighbors
- Message delete via context menu
- Radio config verification diagnostic
- Channel secret correctly parsed from device
- Comprehensive protocol audit against firmware source

## Privacy URL
https://gist.github.com/mbedworth/7cccc52eec16626a5ad7f5328b456fb3

## Support URL
https://gist.github.com/mbedworth/7cccc52eec16626a5ad7f5328b456fb3

## Categories
- Primary: Social Networking
- Secondary: Utilities
