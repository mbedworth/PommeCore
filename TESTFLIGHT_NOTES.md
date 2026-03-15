# TestFlight Materials

## App Store Description

MeshCore — Off-Grid Mesh Messaging

Send encrypted text messages without cellular service, WiFi, or internet using MeshCore LoRa radios. MeshCore creates a decentralized mesh network where messages hop between radios to reach their destination — even miles away.

Features:
- Direct encrypted messaging between MeshCore devices
- Group channels (public and private)
- Room server chat — messages persist even when you're offline
- Remote management of repeaters and room servers over LoRa
- Background Bluetooth — stay connected even when the app is in the background
- Favourite contacts with sync to your radio
- Saved login credentials for quick access to infrastructure
- Full dark mode support

Requires a MeshCore-compatible LoRa radio (Heltec Mesh Pocket, Heltec V3, RAK WisMesh, T-Beam, T-Deck, and more). Flash MeshCore firmware at flasher.meshcore.co.uk.

MeshCore is open source. Learn more at github.com/meshcore-dev/MeshCore.

---

## Beta Test Notes

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

Please report bugs via TestFlight feedback.

---

## Export Compliance

MeshCore uses end-to-end encryption, but the encryption is implemented in the radio firmware (C++), not in the app itself. The app transmits pre-encrypted binary frames over BLE.

For the App Store export compliance questionnaire:
- Does your app use encryption? → Yes
- Is your app exempt from export compliance documentation? → Likely Yes (the app itself doesn't implement encryption — it passes through encrypted payloads from the firmware)
- If asked for more detail: The app uses Apple's standard Bluetooth APIs. Encryption is performed by the connected hardware device's firmware, not by the app.
