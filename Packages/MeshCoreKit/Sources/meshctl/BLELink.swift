//
//  BLELink.swift
//  meshctl
//
//  Minimal CoreBluetooth client for the MeshCore Nordic UART Service.
//
//  Deliberately separate from MeshCoreKit's BLEManager: that type carries app
//  concerns (@Published state, background restoration, auto-reconnect) that a
//  one-shot command-line run neither needs nor wants. This speaks the same
//  service/characteristic UUIDs and uses the same write-type selection, so the
//  radio cannot tell the difference.
//
//  Created by Michael P. Bedworth on 10/02/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import Foundation
import CoreBluetooth
import MeshCoreKit

enum LinkError: Error, CustomStringConvertible {
    case bluetoothUnavailable(String)
    case notFound(String)
    case connectFailed(String)
    case timeout(String)

    var description: String {
        switch self {
        case .bluetoothUnavailable(let s): return "Bluetooth unavailable: \(s)"
        case .notFound(let s): return "Not found: \(s)"
        case .connectFailed(let s): return "Connect failed: \(s)"
        case .timeout(let s): return "Timed out: \(s)"
        }
    }
}

/// One discovered advertiser.
struct Discovered {
    let peripheral: CBPeripheral
    let name: String
    let rssi: Int
}

/// A connected link to a MeshCore radio. One BLE notification is one protocol
/// frame — the firmware never splits a frame across notifications — so inbound
/// bytes need no reassembly.
final class BLELink: NSObject, @unchecked Sendable {

    private let queue = DispatchQueue(label: "meshctl.ble")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?

    /// Every frame received since connect, in order. Also used for fixture
    /// capture. Only touched on `queue`.
    private var frames: [Data] = []

    private var poweredOnContinuation: CheckedContinuation<Void, Error>?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var discoveries: [String: Discovered] = [:]
    private var onDiscovery: ((Discovered) -> Void)?

    /// Frame observers, invoked on the BLE queue as frames arrive.
    private var frameObservers: [(Data) -> Void] = []

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    // MARK: - Lifecycle

    /// Wait for the Bluetooth stack to come up, surfacing the real reason if it does not.
    func waitForPowerOn(timeout: TimeInterval = 10) async throws {
        if central.state == .poweredOn { return }
        try await withTimeout(timeout, label: "Bluetooth power-on") {
            try await withCheckedThrowingContinuation { cont in
                self.queue.async { self.poweredOnContinuation = cont }
            }
        }
    }

    /// Scan for MeshCore advertisers for `duration`, newest RSSI per device.
    func scan(duration: TimeInterval, onFound: ((Discovered) -> Void)? = nil) async throws -> [Discovered] {
        try await waitForPowerOn()
        queue.sync {
            self.onDiscovery = onFound
            self.discoveries = [:]
            // Some MeshCore builds do not advertise the NUS service UUID, so scan
            // broadly and filter by name prefix instead.
            self.central.scanForPeripherals(withServices: nil,
                                            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        queue.sync {
            self.central.stopScan()
            self.onDiscovery = nil
        }
        return queue.sync { Array(self.discoveries.values).sorted { $0.rssi > $1.rssi } }
    }

    /// Connect to the first device whose name contains `nameFilter` (or the
    /// strongest MeshCore device when nil), then wait until the NUS
    /// characteristics are discovered and notifications are live.
    func connect(nameFilter: String?, scanTimeout: TimeInterval = 12) async throws {
        let found = try await scan(duration: scanTimeout)
        guard !found.isEmpty else {
            throw LinkError.notFound("no MeshCore devices advertising (is the radio powered on and not already connected elsewhere?)")
        }
        let target: Discovered
        if let nameFilter {
            guard let match = found.first(where: { $0.name.localizedCaseInsensitiveContains(nameFilter) }) else {
                let names = found.map(\.name).joined(separator: ", ")
                throw LinkError.notFound("no device matching \"\(nameFilter)\" — saw: \(names)")
            }
            target = match
        } else {
            target = found[0]
        }

        FileHandle.standardError.write(Data("  connecting to \(target.name) (RSSI \(target.rssi))\n".utf8))

        try await withTimeout(20, label: "connect to \(target.name)") {
            try await withCheckedThrowingContinuation { cont in
                self.queue.async {
                    self.readyContinuation = cont
                    self.peripheral = target.peripheral
                    target.peripheral.delegate = self
                    self.central.connect(target.peripheral, options: nil)
                }
            }
        }
    }

    func disconnect() {
        queue.sync {
            if let peripheral { central.cancelPeripheralConnection(peripheral) }
        }
    }

    // MARK: - I/O

    /// Write one frame, using the same write-type selection as the app.
    func send(_ data: Data) {
        queue.sync {
            guard let peripheral, let rx = rxCharacteristic else { return }
            let writeType: CBCharacteristicWriteType = rx.properties.contains(.writeWithoutResponse)
                ? .withoutResponse
                : .withResponse
            peripheral.writeValue(data, for: rx, type: writeType)
        }
    }

    /// Send a frame and collect every frame that arrives within `window`.
    ///
    /// Deliberately time-boxed rather than stopping at the first reply: a single
    /// command can produce several frames (a contacts sync, or an immediate OK
    /// followed much later by a pushed telemetry response), and asserting on the
    /// first one would miss the interesting one.
    func request(_ data: Data, window: TimeInterval) async -> [Data] {
        // Observers run on the BLE serial queue, so that queue — not a lock — is
        // what orders writes against the read below. A lock held across an await
        // is unavailable in asynchronous contexts anyway.
        let collected = Box<[Data]>([])
        let token = addObserver { frame in collected.value.append(frame) }
        send(data)
        try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
        removeObserver(token)
        return queue.sync { collected.value }
    }

    /// Wait up to `timeout` for a frame satisfying `predicate`, returning it.
    func waitForFrame(timeout: TimeInterval, matching predicate: @escaping (Data) -> Bool) async -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        let box = Box<Data?>(nil)
        let token = addObserver { frame in
            if box.value == nil, predicate(frame) { box.value = frame }
        }
        defer { removeObserver(token) }
        while Date() < deadline {
            if let hit = box.value { return hit }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    private func addObserver(_ observer: @escaping (Data) -> Void) -> Int {
        queue.sync {
            frameObservers.append(observer)
            return frameObservers.count - 1
        }
    }

    private func removeObserver(_ token: Int) {
        queue.sync {
            if token < frameObservers.count { frameObservers[token] = { _ in } }
        }
    }

    private func record(_ frame: Data) {
        frames.append(frame)
        for observer in frameObservers { observer(frame) }
    }

    var capturedFrames: [Data] {
        queue.sync { frames }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLELink: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard let cont = poweredOnContinuation else { return }
        poweredOnContinuation = nil
        switch central.state {
        case .poweredOn:
            cont.resume()
        case .unauthorized:
            cont.resume(throwing: LinkError.bluetoothUnavailable(
                "this binary is not authorised to use Bluetooth. Grant it in System Settings → Privacy & Security → Bluetooth (the prompt is attributed to the terminal app that launched it)."))
        case .poweredOff:
            cont.resume(throwing: LinkError.bluetoothUnavailable("Bluetooth is turned off"))
        case .unsupported:
            cont.resume(throwing: LinkError.bluetoothUnavailable("no Bluetooth LE hardware"))
        default:
            poweredOnContinuation = cont // still settling — keep waiting
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? ""
        guard name.hasPrefix(BLEConstants.deviceNamePrefix) || !name.isEmpty else { return }
        guard name.hasPrefix(BLEConstants.deviceNamePrefix) else { return }

        let found = Discovered(peripheral: peripheral, name: name, rssi: RSSI.intValue)
        if discoveries[name] == nil { onDiscovery?(found) }
        discoveries[name] = found
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([BLEConstants.nusServiceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        let cont = readyContinuation
        readyContinuation = nil
        cont?.resume(throwing: LinkError.connectFailed(error?.localizedDescription ?? "unknown"))
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        let cont = readyContinuation
        readyContinuation = nil
        cont?.resume(throwing: LinkError.connectFailed("disconnected: \(error?.localizedDescription ?? "clean")"))
    }
}

// MARK: - CBPeripheralDelegate

extension BLELink: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == BLEConstants.nusServiceUUID }) else {
            let cont = readyContinuation
            readyContinuation = nil
            cont?.resume(throwing: LinkError.connectFailed("device has no MeshCore NUS service"))
            return
        }
        peripheral.discoverCharacteristics(
            [BLEConstants.nusRXCharacteristicUUID, BLEConstants.nusTXCharacteristicUUID],
            for: service
        )
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case BLEConstants.nusRXCharacteristicUUID:
                rxCharacteristic = characteristic
            case BLEConstants.nusTXCharacteristicUUID:
                peripheral.setNotifyValue(true, for: characteristic)
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == BLEConstants.nusTXCharacteristicUUID,
              characteristic.isNotifying, rxCharacteristic != nil else { return }
        let cont = readyContinuation
        readyContinuation = nil
        cont?.resume()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == BLEConstants.nusTXCharacteristicUUID,
              let data = characteristic.value, !data.isEmpty else { return }
        record(data)
    }
}

// MARK: - Small helpers

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Race an operation against a timeout, reporting which operation timed out.
func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                              label: String,
                              _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw LinkError.timeout(label)
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
