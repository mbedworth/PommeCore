import Foundation

/// A MeshCore channel for group communication.
public struct Channel: Identifiable, Codable, Sendable {
    public let id: UInt8

    /// Channel display name.
    public let name: String

    /// Channel index on the device.
    public let index: UInt8

    public init(name: String, index: UInt8) {
        self.id = index
        self.name = name
        self.index = index
    }
}
