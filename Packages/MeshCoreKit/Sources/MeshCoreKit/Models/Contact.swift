import Foundation

/// Contact type from the MeshCore protocol.
public enum ContactType: UInt8, Codable, Sendable {
    case chat = 1       // Regular chat contact
    case repeater = 2   // Repeater/relay node
    case room = 3       // Room server
    case unknown = 0
}

/// A MeshCore contact discovered on the mesh network.
public struct Contact: Identifiable, Codable, Sendable {
    /// Use first 6 bytes of publicKey as stable ID.
    public var id: Data { publicKeyPrefix }

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
    public let lastAdvert: UInt32

    /// Advertised latitude (degrees × 1,000,000).
    public let latitude: Double

    /// Advertised longitude (degrees × 1,000,000).
    public let longitude: Double

    /// Last modification timestamp (for incremental sync).
    public let lastmod: UInt32

    /// Last time this contact was seen on the mesh (derived from lastAdvert).
    public var lastSeen: Date {
        lastAdvert > 0 ? Date(timeIntervalSince1970: TimeInterval(lastAdvert)) : Date.distantPast
    }

    public init(
        publicKey: Data,
        name: String,
        type: ContactType = .chat,
        flags: UInt8 = 0,
        outPathLen: Int8 = -1,
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
        self.lastAdvert = lastAdvert
        self.latitude = latitude
        self.longitude = longitude
        self.lastmod = lastmod
    }
}
