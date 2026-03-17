import Foundation

/// Delivery status for outgoing messages.
public enum DeliveryStatus: String, Codable, Sendable {
    case sending    // queued, not yet confirmed by device
    case sent       // device accepted it (RESP_CODE_SENT received)
    case delivered  // ACK received from recipient (PUSH_CODE_SEND_CONFIRMED)
    case failed     // send timed out or errored
}

/// A text message sent or received via the MeshCore mesh network.
public struct Message: Identifiable, Codable, Sendable {
    public let id: UUID

    /// Public key hash of the sender (empty Data for outgoing).
    public let senderKeyHash: Data

    /// Public key hash of the contact this message belongs to.
    public let contactKeyHash: Data

    /// Message text content.
    public let text: String

    /// Timestamp when the message was sent or received.
    public let timestamp: Date

    /// Whether this message was sent by the local user.
    public let isOutgoing: Bool

    /// Delivery status for outgoing messages.
    public var status: DeliveryStatus

    /// Expected ACK code from the device (for tracking delivery confirmation).
    public var expectedACK: UInt32?

    /// SNR of the received message (raw value from protocol, divide by 4.0 for dB).
    public let snr: Int8?

    /// Hop count from the received message (0 = direct, 0xFF = routed/unknown, >0 = number of hops).
    public let hops: UInt8?

    /// Channel index (for channel messages, nil for direct).
    public let channelIndex: UInt8?

    /// Sender name (for channel messages).
    public let senderName: String?

    /// Round-trip time in milliseconds (set on delivery confirmation).
    public var roundTripMs: UInt32?

    /// Text type: 0 = plain text, 1 = CLI data. Used to route CLI responses to management.
    public let txtType: UInt8

    /// Send attempt number (0 = first try, increments on retry, max 3).
    public var attempt: UInt8

    /// Whether this message was cryptographically signed (txt_type=2).
    public let isSigned: Bool

    public init(
        id: UUID = UUID(),
        senderKeyHash: Data = Data(),
        contactKeyHash: Data = Data(),
        text: String,
        timestamp: Date,
        isOutgoing: Bool,
        status: DeliveryStatus = .sending,
        expectedACK: UInt32? = nil,
        snr: Int8? = nil,
        hops: UInt8? = nil,
        channelIndex: UInt8? = nil,
        senderName: String? = nil,
        roundTripMs: UInt32? = nil,
        txtType: UInt8 = 0,
        attempt: UInt8 = 0,
        isSigned: Bool = false
    ) {
        self.id = id
        self.senderKeyHash = senderKeyHash
        self.contactKeyHash = contactKeyHash
        self.text = text
        self.timestamp = timestamp
        self.isOutgoing = isOutgoing
        self.status = status
        self.expectedACK = expectedACK
        self.snr = snr
        self.hops = hops
        self.channelIndex = channelIndex
        self.senderName = senderName
        self.roundTripMs = roundTripMs
        self.txtType = txtType
        self.attempt = attempt
        self.isSigned = isSigned
    }
}
