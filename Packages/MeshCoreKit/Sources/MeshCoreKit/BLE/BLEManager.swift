import CoreBluetooth
import Combine
import os.log

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

    // MARK: - Private Properties

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?
    private let bleQueue = DispatchQueue(label: BLEConstants.bleQueueLabel, qos: .userInitiated)

    /// When true, auto-reconnect on disconnect. Set to false on user-initiated disconnect.
    private var shouldAutoReconnect = false

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
    public func startScanning() {
        guard centralManager.state == .poweredOn else {
            Self.logger.warning("Cannot scan — Bluetooth not powered on (state: \(String(describing: self.centralManager.state.rawValue)))")
            return
        }

        DispatchQueue.main.async {
            self.discoveredPeripherals.removeAll()
            self.connectionState = .scanning
        }

        centralManager.scanForPeripherals(
            withServices: [BLEConstants.nusServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        Self.logger.info("Started scanning for MeshCore devices")
    }

    /// Stop scanning.
    public func stopScanning() {
        centralManager.stopScan()
        DispatchQueue.main.async {
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
        case .poweredOff, .unauthorized, .unsupported:
            DispatchQueue.main.async {
                self.isPoweredOn = false
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

            DispatchQueue.main.async {
                self.connectedDeviceName = peripheral.name
                self.connectionState = .connected
            }

            Self.logger.info("Restored peripheral: \(peripheral.name ?? "unknown")")
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
        Self.logger.info("Connected to \(peripheral.name ?? "unknown")")

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
        Self.logger.info("Disconnected from \(peripheral.name ?? "unknown"), error: \(error?.localizedDescription ?? "none")")

        DispatchQueue.main.async {
            self.rxCharacteristic = nil
            self.txCharacteristic = nil
        }

        if shouldAutoReconnect {
            // Auto-reconnect — CoreBluetooth will queue this and execute even while suspended
            DispatchQueue.main.async {
                self.connectionState = .connecting
            }
            central.connect(peripheral, options: nil)
            Self.logger.info("Queued auto-reconnect for \(peripheral.name ?? "unknown")")
        } else {
            DispatchQueue.main.async {
                self.connectionState = .disconnected
                self.connectedPeripheral = nil
                self.connectedDeviceName = nil
            }
        }
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
