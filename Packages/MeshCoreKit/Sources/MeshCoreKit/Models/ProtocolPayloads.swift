//
//  ProtocolPayloads.swift
//  MeshCoreKit
//
//  Parsed protocol response structs: status, telemetry, trace, and stats.
//
//  Created by Michael P. Bedworth on 3/14/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import Foundation

/// A node discovered via the discover feature (PUSH_CODE_CONTROL_DATA).
public struct DiscoveredNode: Identifiable, Sendable {
    public var id: Data { publicKey }

    public let publicKey: Data
    public let name: String
    public let type: ContactType
    public let snr: Int8
    public let rssi: Int8
    public let pathLen: UInt8
    public let latitude: Double
    public let longitude: Double

    public init(publicKey: Data, name: String, type: ContactType, snr: Int8, rssi: Int8, pathLen: UInt8, latitude: Double = 0, longitude: Double = 0) {
        self.publicKey = publicKey
        self.name = name
        self.type = type
        self.snr = snr
        self.rssi = rssi
        self.pathLen = pathLen
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// A hop in a trace route result.
public struct TraceHop: Identifiable, Sendable {
    public let id = UUID()
    public let nodeHash: Data
    public let snr: Int8

    public init(nodeHash: Data, snr: Int8) {
        self.nodeHash = nodeHash
        self.snr = snr
    }
}

/// Result of a trace route request.
public struct TraceResult: Sendable {
    public let tag: UInt32
    public let hops: [TraceHop]

    public init(tag: UInt32, hops: [TraceHop]) {
        self.tag = tag
        self.hops = hops
    }
}

/// A telemetry reading from a sensor contact.
///
/// Cayenne LPP groups readings into *data channels*: firmware puts the node's own
/// values on `selfChannel` and gives every attached sensor its own channel, so a
/// single response can legitimately carry several readings of the same type
/// (firmware 1.17.0 added MCU temperature on the self channel alongside any
/// external temperature sensor). `name` is the reading type; `key` and `label`
/// are made unique across a response by `disambiguate(_:)`.
public struct TelemetryReading: Identifiable, Sendable {
    /// LPP data channel used by firmware for the node's own values (TELEM_CHANNEL_SELF).
    public static let selfChannel: UInt8 = 1

    public let id = UUID()
    /// Reading type, e.g. "Temperature". Not unique within a response.
    public let name: String
    public let value: Double
    public let unit: String
    /// LPP data channel this reading arrived on.
    public let channel: UInt8
    /// Stable identity within a response — used to key history. Unique after `disambiguate(_:)`.
    public let key: String
    /// Human-readable label, channel-qualified only when `name` alone would be ambiguous.
    public let label: String

    public init(name: String, value: Double, unit: String,
                channel: UInt8 = TelemetryReading.selfChannel,
                key: String? = nil, label: String? = nil) {
        self.name = name
        self.value = value
        self.unit = unit
        self.channel = channel
        self.key = key ?? name
        self.label = label ?? name
    }

    /// Assign unique `key`/`label` values across a single response.
    ///
    /// A reading whose type appears once keeps its plain name — the common single-sensor
    /// case is unchanged for the user. Repeated types are qualified by channel, and the
    /// rare same-channel repeat (an ambient sensor plus MCU temperature, both on the self
    /// channel) gets a trailing index. Order is preserved: firmware emits sensor values
    /// and the node's own values in a different order depending on the request path, so
    /// position is never used to identify a reading.
    public static func disambiguate(_ readings: [TelemetryReading]) -> [TelemetryReading] {
        var countByName: [String: Int] = [:]
        for reading in readings { countByName[reading.name, default: 0] += 1 }

        var seenByChannelName: [String: Int] = [:]
        return readings.map { reading in
            let channelName = "\(reading.channel):\(reading.name)"
            let occurrence = (seenByChannelName[channelName] ?? 0) + 1
            seenByChannelName[channelName] = occurrence

            let suffix = occurrence > 1 ? "#\(occurrence)" : ""
            let key = channelName + suffix
            let isAmbiguous = (countByName[reading.name] ?? 0) > 1
            let label: String
            if !isAmbiguous {
                label = reading.name
            } else if occurrence > 1 {
                label = "\(reading.name) (Ch \(reading.channel) #\(occurrence))"
            } else {
                label = "\(reading.name) (Ch \(reading.channel))"
            }

            return TelemetryReading(name: reading.name, value: reading.value, unit: reading.unit,
                                    channel: reading.channel, key: key, label: label)
        }
    }
}

/// Status response from a remote device.
public struct RemoteStatusInfo: Sendable {
    public let batteryMV: UInt16
    public let uptime: UInt32
    public let contacts: UInt16
    public let rawData: Data

    public init(batteryMV: UInt16, uptime: UInt32, contacts: UInt16, rawData: Data) {
        self.batteryMV = batteryMV
        self.uptime = uptime
        self.contacts = contacts
        self.rawData = rawData
    }
}

/// An allowed repeat frequency range. Values are in kHz (matching firmware FreqRange struct).
public struct FrequencyRange: Sendable {
    public let lowerKHz: UInt32
    public let upperKHz: UInt32

    public init(lowerKHz: UInt32, upperKHz: UInt32) {
        self.lowerKHz = lowerKHz
        self.upperKHz = upperKHz
    }
}

/// Result of a path discovery request (PUSH_CODE_PATH_DISCOVERY_RESPONSE 0x8D).
/// Contains bidirectional path info: how to reach the contact (outPath) and how the contact reaches us (inPath).
public struct PathDiscoveryResult: Sendable {
    public let pubKeyPrefix: Data    // 6 bytes
    public let outPathLen: UInt8     // encoded: hopCount = outPathLen & 0x3F
    public let outPathBytes: Data
    public let inPathLen: UInt8      // encoded: hopCount = inPathLen & 0x3F
    public let inPathBytes: Data
    public let timestamp: Date

    public var outHopCount: Int { Int(outPathLen & 0x3F) }
    public var inHopCount: Int { Int(inPathLen & 0x3F) }

    public init(pubKeyPrefix: Data, outPathLen: UInt8, outPathBytes: Data, inPathLen: UInt8, inPathBytes: Data, timestamp: Date) {
        self.pubKeyPrefix = pubKeyPrefix
        self.outPathLen = outPathLen
        self.outPathBytes = outPathBytes
        self.inPathLen = inPathLen
        self.inPathBytes = inPathBytes
        self.timestamp = timestamp
    }
}

/// Advert path info for a contact.
public struct AdvertPathInfo: Sendable {
    public let recvTimestamp: UInt32
    public let pathLen: UInt8
    public let pathHashes: [Data]

    public init(recvTimestamp: UInt32, pathLen: UInt8, pathHashes: [Data]) {
        self.recvTimestamp = recvTimestamp
        self.pathLen = pathLen
        self.pathHashes = pathHashes
    }
}
