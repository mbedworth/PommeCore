//
//  MeshProfileExport.swift
//  PommeCore
//
//  Versioned Codable model for .meshprofile config export files.
//  Version history:
//    1 — initial: radio params + channels. privateKeyHex reserved (always nil).
//

import Foundation

struct MeshProfileExport: Codable {
    let version: Int
    let exportedAt: Date
    let appVersion: String
    let radio: MeshProfileRadio
    let channels: [MeshProfileChannel]
    // Reserved — always nil until firmware adds PIN-protected binary key export.
    let privateKeyHex: String?
    let exportedWithPIN: Bool?

    static let currentVersion = 1
}

struct MeshProfileRadio: Codable {
    let deviceName: String
    let advertName: String
    let radioFrequency: UInt32    // kHz × 1000
    let radioBandwidth: UInt32    // Hz
    let radioSpreadingFactor: UInt8
    let radioCodingRate: UInt8
    let radioTXPower: UInt8
    let repeatMode: Bool
    let manualAddContacts: UInt8
    let telemetryBase: UInt8
    let telemetryLocation: UInt8
    let advertLocPolicy: UInt8
    let multiACK: UInt8
    let autoAddBitmask: UInt8
    let defaultFloodScope: String
    let rxDelayBase: UInt32
    let airtimeFactor: UInt32
}

struct MeshProfileChannel: Codable {
    let index: UInt8
    let name: String
    let flags: UInt8
    // 16-byte PSK as lowercase hex. Nil for public channel (index 0) and hash channels.
    let secretHex: String?
}
