import CoreBluetooth
import Combine
import os.log
#if os(iOS)
import UIKit
#endif

/// Connection state for BLE device.
public enum BLEConnectionState: Equatable, Sendable {
    case disconnected
    case scanning
    case connecting
    case connected
    case ready // NUS service discovered, TX subscribed
}

/// A discovered MeshCore BLE peripheral.
public struct DiscoveredPeripheral: Identifiable, Equatable {
    public let id: UUID
    public let peripheral: CBPeripheral
    public let name: String
    public let rssi: Int

    public static func == (lhs: DiscoveredPeripheral, rhs: DiscoveredPeripheral) -> Bool {
        lhs.id == rhs.id && lhs.rssi == rhs.rssi
    }
}

/// Manages BLE communication with MeshCore devices via Nordic UART Service.
///
/// Handles scanning, connecting, service/characteristic discovery, background state
/// restoration, and auto-reconnect on disconnect.
public final class BLEManager: NSObject, ObservableObject {
    private static let logger = Logger(subsystem: "com.meshcore", category: "BLE")

    // MARK: - Published State

    @Published public private(set) var connectionState: BLEConnectionState = .disconnected
    @Published public private(set) var discoveredPeripherals: [DiscoveredPeripheral] = []
    @Published public private(set) var connectedDeviceName: String?
    @Published public private(set) var isPoweredOn: Bool = false

    /// User-facing BLE status message for error states (nil when no issue).
    @Published public private(set) var bleStatusMessage: String?

    // MARK: - Private Properties

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?
    private let bleQueue = DispatchQueue(label: BLEConstants.bleQueueLabel, qos: .userInitiated)

    /// When true, auto-reconnect on disconnect. Set to false on user-initiated disconnect.
    private var shouldAutoReconnect = false

    /// Number of auto-reconnect attempts remaining for unexpected disconnects.
    private var reconnectAttemptsRemaining = 0

    /// Maximum auto-reconnect attempts before giving up.
    private static let maxReconnectAttempts = 3

    /// Work item for the reconnect timeout (cancelled on successful reconnect).
    private var reconnectTimeoutWork: DispatchWorkItem?

    /// Publisher for incoming data frames from the device TX characteristic.
    public let receivedDataSubject = PassthroughSubject<Data, Never>()

    // MARK: - Init

    public override init() {
        super.init()
        centralManager = CBCentralManager(
            delegate: self,
            queue: bleQueue,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: BLEConstants.centralManagerRestoreIdentifier
            ]
        )
    }

    // MARK: - Public API

    /// Start scanning for MeshCore devices.
    /// Safe to call while connected — will not change connection state.
    public func startScanning() {
        guard centralManager.state == .poweredOn else {
            Self.logger.warning("Cannot scan — Bluetooth not powered on (state: \(String(describing: self.centralManager.state.rawValue)))")
            return
        }

        #if os(iOS)
        // Don't scan if we have a pending reconnect — CoreBluetooth manages it
        if connectedPeripheral != nil && connectionState == .connecting {
            Self.logger.info("Skipping scan — reconnect pending for \(self.connectedPeripheral?.name ?? "unknown")")
            return
        }
        #endif

        DispatchQueue.main.async {
            self.discoveredPeripherals.removeAll()
            if self.connectionState != .ready && self.connectionState != .connected && self.connectionState != .connecting {
                self.connectionState = .scanning
            }
        }

        centralManager.scanForPeripherals(
            withServices: [BLEConstants.nusServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        Self.logger.info("Started scanning for MeshCore devices")
    }

    /// Stop scanning. Safe to call at any time — only changes state if currently scanning.
    public func stopScanning() {
        centralManager.stopScan()
        DispatchQueue.main.async {
            // Only reset to disconnected if we were purely scanning (not connected)
            if self.connectionState == .scanning {
                self.connectionState = .disconnected
            }
        }
        Self.logger.info("Stopped scanning")
    }

    /// Connect to a discovered peripheral.
    public func connect(to peripheral: CBPeripheral) {
        stopScanning()

        DispatchQueue.main.async {
            self.connectionState = .connecting
        }

        shouldAutoReconnect = true
        reconnectAttemptsRemaining = Self.maxReconnectAttempts
        connectedPeripheral = peripheral
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)

        Self.logger.info("Connecting to \(peripheral.name ?? "unknown")")
    }

    /// Disconnect from the current peripheral.
    public func disconnect() {
        guard let peripheral = connectedPeripheral else { return }
        shouldAutoReconnect = false
        centralManager.cancelPeripheralConnection(peripheral)
        Self.logger.info("Disconnecting from \(peripheral.name ?? "unknown")")
    }

    /// Write data to the device RX characteristic.
    public func send(data: Data) {
        guard let peripheral = connectedPeripheral,
              let rx = rxCharacteristic else {
            Self.logger.warning("Cannot send — not connected or RX characteristic not found")
            return
        }

        let writeType: CBCharacteristicWriteType = rx.properties.contains(.writeWithoutResponse)
            ? .withoutResponse
            : .withResponse

        peripheral.writeValue(data, for: rx, type: writeType)
        Self.logger.debug("Sent \(data.count) bytes to device")
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Self.logger.info("Central manager state: \(String(describing: central.state.rawValue))")

        switch central.state {
        case .poweredOn:
            DispatchQueue.main.async {
                self.isPoweredOn = true
                self.bleStatusMessage = nil
            }
            // If we had a connected peripheral from restoration, re-discover services
            if let peripheral = connectedPeripheral {
                peripheral.delegate = self
                if peripheral.state == .connected {
                    peripheral.discoverServices([BLEConstants.nusServiceUUID])
                } else {
                    central.connect(peripheral, options: nil)
                }
            }
        case .poweredOff:
            Self.logger.warning("Bluetooth is powered off")
            DispatchQueue.main.async {
                self.isPoweredOn = false
                self.bleStatusMessage = "Bluetooth is turned off. Enable Bluetooth in Settings to connect to your radio."
                self.connectionState = .disconnected
                self.connectedPeripheral = nil
                self.rxCharacteristic = nil
                self.txCharacteristic = nil
            }
        case .unauthorized:
            Self.logger.warning("Bluetooth permission denied")
            DispatchQueue.main.async {
                self.isPoweredOn = false
                self.bleStatusMessage = "Bluetooth access denied. Enable Bluetooth for MeshCore in Settings \u{2192} Privacy \u{2192} Bluetooth."
                self.connectionState = .disconnected
                self.connectedPeripheral = nil
                self.rxCharacteristic = nil
                self.txCharacteristic = nil
            }
        case .unsupported:
            Self.logger.warning("Bluetooth not supported on this device")
            DispatchQueue.main.async {
                self.isPoweredOn = false
                self.bleStatusMessage = "This device does not support Bluetooth Low Energy."
                self.connectionState = .disconnected
                self.connectedPeripheral = nil
                self.rxCharacteristic = nil
                self.txCharacteristic = nil
            }
        default:
            break
        }
    }

    /// State restoration — called when iOS relaunches app after termination.
    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        Self.logger.info("Restoring BLE state")

        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let peripheral = peripherals.first {
            peripheral.delegate = self
            connectedPeripheral = peripheral
            shouldAutoReconnect = true

            DispatchQueue.main.async {
                self.connectedDeviceName = peripheral.name
                self.connectionState = .connected
            }

            // Re-discover services to re-subscribe to TX notifications
            if peripheral.state == .connected {
                Self.logger.info("Restored connected peripheral — re-discovering services")
                peripheral.discoverServices([BLEConstants.nusServiceUUID])
            } else {
                Self.logger.info("Restored disconnected peripheral — queuing reconnect")
                central.connect(peripheral, options: nil)
                DispatchQueue.main.async {
                    self.connectionState = .connecting
                }
            }

            Self.logger.info("Restored peripheral: \(peripheral.name ?? "unknown"), state: \(peripheral.state.rawValue)")
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // We scan with NUS service UUID filter, so any device found here speaks NUS.
        // peripheral.name is often nil on the first callback — fall back to advertisement data.
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? "MeshCore Device"

        let discovered = DiscoveredPeripheral(
            id: peripheral.identifier,
            peripheral: peripheral,
            name: name,
            rssi: RSSI.intValue
        )

        DispatchQueue.main.async {
            if let index = self.discoveredPeripherals.firstIndex(where: { $0.id == discovered.id }) {
                self.discoveredPeripherals[index] = discovered
            } else {
                self.discoveredPeripherals.append(discovered)
            }
        }

        Self.logger.info("Discovered \(name) (RSSI: \(RSSI.intValue))")
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        #if os(iOS)
        let bgState = DispatchQueue.main.sync { UIApplication.shared.applicationState }
        let isBackground = bgState != .active
        Self.logger.info("Connected to \(peripheral.name ?? "unknown") (background: \(isBackground))")
        #else
        Self.logger.info("Connected to \(peripheral.name ?? "unknown")")
        #endif

        reconnectAttemptsRemaining = Self.maxReconnectAttempts
        reconnectTimeoutWork?.cancel()
        reconnectTimeoutWork = nil

        DispatchQueue.main.async {
            self.connectionState = .connected
            self.connectedDeviceName = peripheral.name
        }

        peripheral.discoverServices([BLEConstants.nusServiceUUID])
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Self.logger.error("Failed to connect: \(error?.localizedDescription ?? "unknown error")")

        #if os(iOS)
        if shouldAutoReconnect {
            // Retry — CoreBluetooth will queue it for when the device is available
            Self.logger.info("iOS: re-queuing connect after failure")
            central.connect(peripheral, options: nil)
            return
        }
        #endif

        DispatchQueue.main.async {
            self.connectionState = .disconnected
            self.connectedPeripheral = nil
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        #if os(iOS)
        let bgState = DispatchQueue.main.sync { UIApplication.shared.applicationState }
        let isBackground = bgState != .active
        Self.logger.info("Disconnected from \(peripheral.name ?? "unknown") (background: \(isBackground), error: \(error?.localizedDescription ?? "none"))")
        #else
        Self.logger.info("Disconnected from \(peripheral.name ?? "unknown"), error: \(error?.localizedDescription ?? "none")")
        #endif

        DispatchQueue.main.async {
            self.rxCharacteristic = nil
            self.txCharacteristic = nil
        }

        let isUnexpected = error != nil && shouldAutoReconnect

        #if os(iOS)
        if shouldAutoReconnect {
            // iOS: ALWAYS queue reconnect for unexpected disconnects.
            // CoreBluetooth manages the reconnect queue even while the app is suspended.
            // This is the key to background BLE — never give up, never clear connectedPeripheral.
            Self.logger.info("iOS: queuing reconnect for \(peripheral.name ?? "unknown") (background-safe)")

            DispatchQueue.main.async {
                self.connectionState = .connecting
            }
            // CoreBluetooth will connect when the device becomes available again
            central.connect(peripheral, options: nil)
        } else {
            // User-initiated disconnect — clean up fully
            reconnectTimeoutWork?.cancel()
            reconnectTimeoutWork = nil

            DispatchQueue.main.async {
                self.connectionState = .disconnected
                self.connectedPeripheral = nil
                self.connectedDeviceName = nil
            }
        }
        #else
        if isUnexpected && reconnectAttemptsRemaining > 0 {
            // Unexpected disconnect — retry up to 3 times with 2-second delays
            reconnectAttemptsRemaining -= 1
            let attempt = Self.maxReconnectAttempts - reconnectAttemptsRemaining
            Self.logger.info("Auto-reconnect attempt \(attempt)/\(Self.maxReconnectAttempts) for \(peripheral.name ?? "unknown")")

            DispatchQueue.main.async {
                self.connectionState = .connecting
            }

            self.bleQueue.asyncAfter(deadline: .now() + 2.0) {
                central.connect(peripheral, options: nil)
            }
        } else {
            // User-initiated disconnect OR reconnect attempts exhausted
            shouldAutoReconnect = false
            reconnectAttemptsRemaining = 0

            DispatchQueue.main.async {
                self.connectionState = .disconnected
                self.connectedPeripheral = nil
                self.connectedDeviceName = nil
            }

            // Auto-scan after 2 seconds so the device is re-discoverable
            self.bleQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, self.centralManager.state == .poweredOn,
                      self.connectionState == .disconnected else { return }
                Self.logger.info("Auto-scanning after disconnect")
                self.startScanning()
            }
        }
        #endif
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            Self.logger.error("Service discovery error: \(error.localizedDescription)")
            return
        }

        guard let service = peripheral.services?.first(where: { $0.uuid == BLEConstants.nusServiceUUID }) else {
            Self.logger.warning("NUS service not found on peripheral")
            return
        }

        peripheral.discoverCharacteristics(
            [BLEConstants.nusRXCharacteristicUUID, BLEConstants.nusTXCharacteristicUUID],
            for: service
        )
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            Self.logger.error("Characteristic discovery error: \(error.localizedDescription)")
            return
        }

        guard let characteristics = service.characteristics else { return }

        for characteristic in characteristics {
            switch characteristic.uuid {
            case BLEConstants.nusRXCharacteristicUUID:
                rxCharacteristic = characteristic
                Self.logger.info("Found NUS RX characteristic")

            case BLEConstants.nusTXCharacteristicUUID:
                txCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                Self.logger.info("Found NUS TX characteristic — subscribing to notifications")

            default:
                break
            }
        }

        if rxCharacteristic != nil && txCharacteristic != nil {
            DispatchQueue.main.async {
                self.connectionState = .ready
            }
            Self.logger.info("NUS service ready — device is fully connected")
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            Self.logger.error("Characteristic update error: \(error.localizedDescription)")
            return
        }

        guard characteristic.uuid == BLEConstants.nusTXCharacteristicUUID,
              let data = characteristic.value else { return }

        Self.logger.debug("Received \(data.count) bytes from device")
        receivedDataSubject.send(data)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            Self.logger.error("Notification state error: \(error.localizedDescription)")
            return
        }

        Self.logger.info("Notification state updated for \(characteristic.uuid): \(characteristic.isNotifying)")
    }
}
