import Foundation

/// Determines which settings/features are available based on device type.
/// Companion radios (BLE-connected local device) have limited features.
/// Repeaters and room servers expose more configuration options.
public struct DeviceCapabilities {
    public let canRepeat: Bool
    public let hasChat: Bool
    public let hasACL: Bool
    public let hasGuestPassword: Bool
    public let hasAdminPassword: Bool
    public let hasNeighbors: Bool
    public let hasReadOnlyMode: Bool
    public let hasPowerSaving: Bool
    public let hasOwnerInfo: Bool
    public let hasAdvertIntervals: Bool
    public let hasRegionManagement: Bool

    /// Companion radio — the locally BLE-connected device. Limited feature set.
    public static let companion = DeviceCapabilities(
        canRepeat: false, hasChat: true, hasACL: false,
        hasGuestPassword: false, hasAdminPassword: false, hasNeighbors: false,
        hasReadOnlyMode: false, hasPowerSaving: false, hasOwnerInfo: false,
        hasAdvertIntervals: false, hasRegionManagement: false
    )

    /// Repeater node — relay-only device with full admin features.
    public static let repeater = DeviceCapabilities(
        canRepeat: true, hasChat: false, hasACL: true,
        hasGuestPassword: true, hasAdminPassword: true, hasNeighbors: true,
        hasReadOnlyMode: false, hasPowerSaving: true, hasOwnerInfo: true,
        hasAdvertIntervals: true, hasRegionManagement: true
    )

    /// Room server — chat-capable managed device with full admin features.
    public static let roomServer = DeviceCapabilities(
        canRepeat: true, hasChat: true, hasACL: true,
        hasGuestPassword: true, hasAdminPassword: true, hasNeighbors: false,
        hasReadOnlyMode: true, hasPowerSaving: true, hasOwnerInfo: true,
        hasAdvertIntervals: true, hasRegionManagement: true
    )

    /// Determine capabilities from contact type.
    public static func forContactType(_ type: ContactType) -> DeviceCapabilities {
        switch type {
        case .repeater: return .repeater
        case .room: return .roomServer
        default: return .companion
        }
    }
}

/// Complete device configuration populated from various response codes.
public final class DeviceConfig: ObservableObject {

    // MARK: - Device Info (from RESP_CODE_DEVICE_INFO code 13 + SELF_INFO code 5)

    @Published public var deviceName: String = ""
    /// Device self type from SELF_INFO: 1=companion, 2=repeater, 3=room server
    @Published public var selfType: UInt8 = 1
    @Published public var firmwareVersion: String = ""  // from DEVICE_INFO firmwareVer byte
    @Published public var buildDate: String = ""         // from DEVICE_INFO 12-char cstring
    @Published public var manufacturer: String = ""      // from DEVICE_INFO null-terminated model
    @Published public var semanticVersion: String = ""   // from DEVICE_INFO null-terminated version
    @Published public var publicKeyHex: String = ""      // from SELF_INFO 32-byte public key
    @Published public var maxTXPower: UInt8 = 22
    @Published public var maxContacts: UInt16 = 0        // from DEVICE_INFO maxContactsDiv2 × 2
    @Published public var maxChannels: UInt8 = 0         // from DEVICE_INFO (group channels)

    // MARK: - Battery (from RESP_CODE_BATT_AND_STORAGE code 12)

    @Published public var batteryMillivolts: UInt16 = 0

    // MARK: - Identity & Advertising

    @Published public var advertName: String = ""
    @Published public var latitude: Double = 0.0
    @Published public var longitude: Double = 0.0
    @Published public var advertLocPolicy: UInt8 = 0  // 0=don't share, 1=share

    // MARK: - Radio Configuration

    @Published public var radioFrequency: UInt32 = 906000  // freq * 1000, kHz
    @Published public var radioBandwidth: UInt32 = 250000   // BW * 1000
    @Published public var radioSpreadingFactor: UInt8 = 12
    @Published public var radioCodingRate: UInt8 = 5  // 5=4/5, 6=4/6, 7=4/7, 8=4/8
    @Published public var radioTXPower: UInt8 = 22
    @Published public var repeatMode: Bool = false

    // MARK: - Tuning Parameters

    @Published public var rxDelayBase: UInt32 = 0  // value * 1000
    @Published public var airtimeFactor: UInt32 = 0 // value * 1000

    // MARK: - Privacy & Security

    @Published public var manualAddContacts: UInt8 = 0
    @Published public var telemetryBase: UInt8 = 0      // bits 0-1
    @Published public var telemetryLocation: UInt8 = 0   // bits 2-3
    @Published public var multiACK: UInt8 = 0
    @Published public var blePIN: UInt32 = 0

    // MARK: - Time

    @Published public var deviceTimeEpoch: UInt32 = 0

    // MARK: - Custom Variables

    @Published public var customVars: [(name: String, value: String)] = []

    // MARK: - Statistics

    // Core stats (sub_type 0)
    @Published public var statsBatteryMV: Int16 = 0
    @Published public var statsUptime: UInt32 = 0
    @Published public var statsErrorFlags: UInt16 = 0
    @Published public var statsQueueLength: UInt8 = 0

    // Radio stats (sub_type 1)
    @Published public var statsNoiseFloor: Int16 = 0
    @Published public var statsLastRSSI: Int8 = 0
    @Published public var statsLastSNR: Int8 = 0          // SNR * 4
    @Published public var statsTXAirtime: UInt32 = 0      // seconds
    @Published public var statsRXAirtime: UInt32 = 0      // seconds

    // Packet stats (sub_type 2)
    @Published public var statsPacketsReceived: UInt32 = 0
    @Published public var statsPacketsSent: UInt32 = 0
    @Published public var statsFloodCount: UInt32 = 0     // sent flood
    @Published public var statsDirectCount: UInt32 = 0    // sent direct
    @Published public var statsRecvFlood: UInt32 = 0
    @Published public var statsRecvDirect: UInt32 = 0

    // MARK: - Loading State

    @Published public var isLoading: Bool = false
    @Published public var loadedSections: Set<String> = []

    public init() {}

    public var batteryVoltage: Double {
        Double(batteryMillivolts) / 1000.0
    }

    /// Battery percentage using the given chemistry profile.
    public func batteryPercent(chemistry: BatteryChemistry = .lipo) -> Int {
        chemistry.profile.percentage(forMillivolts: Int(batteryMillivolts))
    }

    public var frequencyMHz: Double {
        Double(radioFrequency) / 1000.0
    }

    public var bandwidthKHz: Double {
        Double(radioBandwidth) / 1000.0
    }

    public var rxDelaySeconds: Double {
        Double(rxDelayBase) / 1000.0
    }

    public var airtimeMultiplier: Double {
        Double(airtimeFactor) / 1000.0
    }

    public var deviceTimeDate: Date? {
        guard deviceTimeEpoch > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(deviceTimeEpoch))
    }
}
