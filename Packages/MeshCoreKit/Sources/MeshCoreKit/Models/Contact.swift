//
//  Contact.swift
//  MeshCoreKit
//
//  Contact model: public key, type, path routing, location, and status.
//
//  Created by Michael P. Bedworth on 3/13/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import Foundation

/// Contact type from the MeshCore protocol.
public enum ContactType: UInt8, Codable, Sendable {
    case chat = 1       // Regular chat contact
    case repeater = 2   // Repeater/relay node
    case room = 3       // Room server
    case sensor = 4     // Sensor node
    case unknown = 0

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(UInt8.self)
        self = ContactType(rawValue: raw) ?? .unknown
    }

    public var displayName: String {
        switch self {
        case .chat: return "Contact"
        case .repeater: return "Repeater"
        case .room: return "Room"
        case .sensor: return "Sensor"
        case .unknown: return "Unknown"
        }
    }
}

/// A MeshCore contact discovered on the mesh network.
public struct Contact: Identifiable, Codable, Sendable, Hashable {
    public static func == (lhs: Contact, rhs: Contact) -> Bool {
        lhs.publicKey == rhs.publicKey &&
        lhs.flags == rhs.flags &&
        lhs.name == rhs.name &&
        lhs.lastAdvert == rhs.lastAdvert &&
        lhs.outPathLen == rhs.outPathLen &&
        lhs.latitude == rhs.latitude &&
        lhs.longitude == rhs.longitude
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(publicKey)
        hasher.combine(flags)
        hasher.combine(name)
        hasher.combine(lastAdvert)
        hasher.combine(outPathLen)
        hasher.combine(latitude)
        hasher.combine(longitude)
    }
    /// Use first 6 bytes of publicKey as stable ID.
    public var id: Data { publicKeyPrefix }

    /// A contact the radio created for a node that has not identified itself.
    ///
    /// Firmware creates these (ADV_TYPE_NONE, no name) when a node that is not in our
    /// contact list sends a telemetry or status request. Firmware 1.17.0 started
    /// returning them from CMD_GET_CONTACTS — earlier firmware filtered them out.
    /// They become normal contacts as soon as an advert names them.
    public var isUnidentified: Bool {
        type == .unknown && name.isEmpty
    }

    /// First 6 bytes of the public key (used for message routing).
    public var publicKeyPrefix: Data {
        Data(publicKey.prefix(6))
    }

    /// Full 32-byte public key.
    public let publicKey: Data

    /// Display name of the contact.
    public let name: String

    /// Contact type (chat, repeater, room server).
    public let type: ContactType

    /// Protocol flags byte.
    public let flags: UInt8

    /// Outbound path length. -1 = no path known, 0 = direct/neighbor.
    public let outPathLen: Int8

    /// Last time this contact advertised (epoch seconds).
    public var lastAdvert: UInt32

    /// Advertised latitude in degrees.
    ///
    /// The protocol carries micro-degrees; the parser divides, so this is
    /// already plain degrees and must be multiplied by 1,000,000 again on the
    /// way back out.
    public let latitude: Double

    /// Advertised longitude in degrees.
    ///
    /// The protocol carries micro-degrees; the parser divides, so this is
    /// already plain degrees and must be multiplied by 1,000,000 again on the
    /// way back out.
    public let longitude: Double

    /// Raw outbound path hashes (up to 64 bytes of routing data for trace route).
    public let outPath: Data

    /// Last modification timestamp (for incremental sync).
    public let lastmod: UInt32

    /// Whether this contact is marked as a favourite (bit 0 of flags).
    public var isFavourite: Bool {
        (flags & 0x01) != 0
    }

    /// Whether this contact is allowed to request telemetry (bit 1 of flags).
    public var allowTelemetry: Bool {
        (flags & 0x02) != 0
    }

    /// Whether to share location in telemetry with this contact (bit 2 of flags).
    public var shareTelemetryLocation: Bool {
        (flags & 0x04) != 0
    }

    /// Last time this contact was seen on the mesh (derived from lastAdvert).
    public var lastSeen: Date {
        lastAdvert > 0 ? lastAdvert.asDate : Date.distantPast
    }

    /// Return a copy with updated flags.
    public func withFlags(_ newFlags: UInt8) -> Contact {
        Contact(
            publicKey: publicKey,
            name: name,
            type: type,
            flags: newFlags,
            outPathLen: outPathLen,
            outPath: outPath,
            lastAdvert: lastAdvert,
            latitude: latitude,
            longitude: longitude,
            lastmod: lastmod
        )
    }

    /// Tolerant decoder, per critical rule 2.
    ///
    /// The synthesized decoder refuses a record missing any single field,
    /// which means one added field makes every older persisted contact
    /// undecodable — and because contacts are decoded as an array, one bad
    /// record takes the whole list with it. That is how a contact backup, the
    /// only thing standing between a mistaken bulk delete and permanent loss,
    /// would fail to load.
    ///
    /// `publicKey` is the only requirement: it is the identity everything else
    /// is keyed by, so a record without it cannot be used for anything.
    /// `ContactType` already decodes unknown values to `.unknown`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        publicKey = try c.decode(Data.self, forKey: .publicKey)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        type = (try? c.decode(ContactType.self, forKey: .type)) ?? .unknown
        flags = (try? c.decode(UInt8.self, forKey: .flags)) ?? 0
        // -1 means "no path known", the correct assumption when unrecorded:
        // a wrong path would route messages into a dead end, whereas no path
        // floods and rediscovers.
        outPathLen = (try? c.decode(Int8.self, forKey: .outPathLen)) ?? -1
        outPath = (try? c.decode(Data.self, forKey: .outPath)) ?? Data()
        lastAdvert = (try? c.decode(UInt32.self, forKey: .lastAdvert)) ?? 0
        latitude = (try? c.decode(Double.self, forKey: .latitude)) ?? 0
        longitude = (try? c.decode(Double.self, forKey: .longitude)) ?? 0
        lastmod = (try? c.decode(UInt32.self, forKey: .lastmod)) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case publicKey, name, type, flags, outPathLen, outPath
        case lastAdvert, latitude, longitude, lastmod
    }

    public init(
        publicKey: Data,
        name: String,
        type: ContactType = .chat,
        flags: UInt8 = 0,
        outPathLen: Int8 = -1,
        outPath: Data = Data(),
        lastAdvert: UInt32 = 0,
        latitude: Double = 0,
        longitude: Double = 0,
        lastmod: UInt32 = 0
    ) {
        self.publicKey = publicKey
        self.name = name
        self.type = type
        self.flags = flags
        self.outPathLen = outPathLen
        self.outPath = outPath
        self.lastAdvert = lastAdvert
        self.latitude = latitude
        self.longitude = longitude
        self.lastmod = lastmod
    }
}
