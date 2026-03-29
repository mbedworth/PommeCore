import SwiftUI
import Combine
import os.log
import MeshCoreKit

/// Observable store for transport state, scanning, connect/disconnect, and sendCommand routing.
/// Extracted from MeshCoreViewModel to enable fine-grained view observation.
@MainActor @Observable
final class ConnectionManager {
    private static let logger = Logger(subsystem: "com.meshcore", category: "ConnectionManager")

    // MARK: - Public State

    var isScanning = false
    var discoveredPeripherals: [DiscoveredPeripheral] = []
    var connectionState: BLEConnectionState = .disconnected
    var connectedDeviceName: String?
    var bleStatusMessage: String?
    var scanRetryCount: Int = 0
    var requestShowScanner = false
    var isInBackground = false

    // MARK: - Transport Managers

    let bleManager = BLEManager()
    let wifiManager = WiFiConnectionManager()
    #if os(macOS) || targetEnvironment(macCatalyst)
    let usbManager = USBSerialManager()
    #endif

    // MARK: - Dependencies (set by coordinator)

    /// Called when a binary frame is received from any transport.
    var onFrameReceived: ((Data) -> Void)?

    /// Called when connection state transitions to .ready (binary mode device connected).
    var onDeviceReady: (() -> Void)?

    /// Called when USB CLI mode is detected.
    var onUSBCLIReady: (() -> Void)?

    /// Called when connection transitions from connected/ready → disconnected.
    var onDisconnected: ((BLEConnectionState) -> Void)?

    /// Called when a USB CLI text line is received.
    var onUSBCLILineReceived: ((String) -> Void)?

    // MARK: - Private State

    private var pendingAutoScan = false
    private let maxScanRetries = 3
    private var scanRetryTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// Routine commands that don't need hex dumps in the in-app debug log.
    private static let routineLabels: Set<String> = [
        "GET_BATT", "GET_TIME", "GET_TUNING", "GET_CUSTOM_VARS", "GET_STATS(0)",
        "GET_STATS(1)", "GET_STATS(2)", "GET_AUTOADD", "APP_START", "DEVICE_QUERY",
    ]

    // MARK: - Init

    init() {
        setupSubscriptions()
    }

    // MARK: - Send Command

    /// Route a command frame to the active transport (WiFi > USB binary > BLE).
    func sendCommand(_ data: Data, label: String) {
        let verbose = !Self.routineLabels.contains(label)

        if wifiManager.isConnected {
            let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
            Self.logger.info("TX(WiFi) \(label) [\(data.count) bytes]: \(hex)")
            if verbose { DebugLogger.shared.log("TX(WiFi) \(label) [\(data.count)B] \(hex)", level: .tx) }
            wifiManager.sendFrame(data)
            return
        }
        #if os(macOS) || targetEnvironment(macCatalyst)
        if usbManager.isConnected && usbManager.detectedMode == .binary {
            let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
            Self.logger.info("TX(USB) \(label) [\(data.count) bytes]: \(hex)")
            if verbose { DebugLogger.shared.log("TX(USB) \(label) [\(data.count)B] \(hex)", level: .tx) }
            usbManager.sendFrame(data)
            return
        }
        #endif
        guard connectionState == .ready || connectionState == .connected else {
            Self.logger.warning("Cannot send \(label) — not connected (state: \(String(describing: self.connectionState)))")
            DebugLogger.shared.log("TX FAIL \(label) — not connected", level: .error)
            return
        }
        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        Self.logger.info("TX \(label) [\(data.count) bytes]: \(hex)")
        if verbose { DebugLogger.shared.log("TX \(label) [\(data.count)B] \(hex)", level: .tx) }
        bleManager.send(data: data)
    }

    // MARK: - Scanning & Connection

    func requestAutoScan() {
        if bleManager.isPoweredOn {
            if connectionState == .disconnected {
                scanRetryCount = maxScanRetries
                startScanning()
            }
        } else {
            pendingAutoScan = true
            scanRetryCount = maxScanRetries
        }
    }

    func startScanning() {
        guard bleManager.isPoweredOn else {
            Self.logger.warning("Cannot scan — BLE not powered on, queuing for later")
            pendingAutoScan = true
            return
        }
        scanRetryTask?.cancel()
        isScanning = true
        bleManager.startScanning()
    }

    func stopScanning() {
        scanRetryTask?.cancel()
        scanRetryTask = nil
        scanRetryCount = 0
        isScanning = false
        bleManager.stopScanning()
    }

    func handleScanTimeout() {
        guard isScanning else { return }
        if discoveredPeripherals.isEmpty && scanRetryCount > 0 {
            scanRetryCount -= 1
            Self.logger.info("Scan found nothing, retrying (\(self.scanRetryCount) retries left)")
            bleManager.stopScanning()
            scanRetryTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                self?.bleManager.startScanning()
            }
        } else if discoveredPeripherals.isEmpty {
            Self.logger.info("Scan retries exhausted, stopping")
            isScanning = false
            bleManager.stopScanning()
        }
    }

    func connect(to peripheral: DiscoveredPeripheral) {
        stopScanning()
        bleManager.connect(to: peripheral.peripheral)
    }

    func connectWiFi(host: String, port: UInt16 = 5000) {
        wifiManager.connect(host: host, port: port)
    }

    func disconnectWiFi() {
        wifiManager.disconnect()
    }

    #if os(macOS) || targetEnvironment(macCatalyst)
    func connectUSB(port: String) {
        usbManager.connect(to: port)
    }

    func disconnectUSB() {
        usbManager.disconnect()
        if connectionState != .disconnected {
            connectionState = .disconnected
            connectedDeviceName = nil
        }
        // Start BLE scan after USB disconnect (same as BLE disconnect behavior)
        DebugLogger.shared.log("USB: disconnected — starting BLE scan in 2s", level: .info)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.connectionState == .disconnected else { return }
            self.startScanning()
        }
    }

    func sendUSBCLI(_ command: String) {
        usbManager.sendCLI(command)
    }

    /// Whether the USB device is CLI-connected.
    var isUSBCLIMode: Bool {
        usbManager.isConnected && usbManager.detectedMode == .cli
    }
    #endif

    func disconnect() {
        bleManager.disconnect()
        // Auto-scan after user-initiated disconnect
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.connectionState == .disconnected else { return }
            self.requestShowScanner = true
            self.startScanning()
        }
    }

    /// Reset scanning and transport state.
    func reset() {
        stopScanning()
        requestShowScanner = false
        bleStatusMessage = nil
    }

    // MARK: - Subscriptions

    private func setupSubscriptions() {
        // BLE received data → frame handler
        bleManager.receivedDataSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data in
                self?.onFrameReceived?(data)
            }
            .store(in: &cancellables)

        // Background fast-path: parse PUSH_CODE_MSG_WAITING immediately on BLE queue
        bleManager.receivedDataSubject
            .sink { [weak self] data in
                guard let self, data.count >= 1 else { return }
                if data[0] == 0x83 {
                    Self.logger.info("BG FAST-PATH: PUSH_CODE_MSG_WAITING — sending SYNC_NEXT_MESSAGE immediately")
                    DebugLogger.shared.log("NOTIF: 0x83 received, sending SYNC_NEXT immediately", level: .rx)
                    self.bleManager.send(data: Data([0x0A]))
                }
            }
            .store(in: &cancellables)

        // BLE discovered peripherals
        bleManager.$discoveredPeripherals
            .receive(on: DispatchQueue.main)
            .sink { [weak self] peripherals in
                self?.discoveredPeripherals = peripherals
            }
            .store(in: &cancellables)

        // BLE connected device name
        bleManager.$connectedDeviceName
            .receive(on: DispatchQueue.main)
            .sink { [weak self] name in
                self?.connectedDeviceName = name
            }
            .store(in: &cancellables)

        // BLE connection state changes
        bleManager.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                let previousState = self.connectionState
                self.connectionState = state

                if state == .disconnected {
                    self.onDisconnected?(previousState)

                    if previousState == .connecting || previousState == .ready {
                        if previousState == .connecting {
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 3_000_000_000)
                                guard self.connectionState == .disconnected else { return }
                                self.requestShowScanner = true
                            }
                        }
                    }
                }
                if state == .ready && previousState != .ready {
                    self.onDeviceReady?()
                }
            }
            .store(in: &cancellables)

        // BLE power state
        bleManager.$isPoweredOn
            .receive(on: DispatchQueue.main)
            .sink { [weak self] poweredOn in
                guard let self, poweredOn, self.pendingAutoScan else { return }
                self.pendingAutoScan = false
                if self.connectionState == .disconnected {
                    self.startScanning()
                }
            }
            .store(in: &cancellables)

        // BLE status message
        bleManager.$bleStatusMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.bleStatusMessage = message
            }
            .store(in: &cancellables)

        // WiFi received data
        wifiManager.receivedDataSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data in
                self?.onFrameReceived?(data)
            }
            .store(in: &cancellables)

        // WiFi connection state
        wifiManager.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                guard let self else { return }
                if connected {
                    Self.logger.info("WiFi connected — initializing device")
                    self.connectionState = .ready
                    self.connectedDeviceName = "WiFi: \(self.wifiManager.connectedHost ?? "unknown")"
                    self.onDeviceReady?()
                } else if self.wifiManager.connectedHost != nil {
                    if self.connectionState == .ready {
                        let prev = self.connectionState
                        self.connectionState = .disconnected
                        self.connectedDeviceName = nil
                        self.onDisconnected?(prev)
                    }
                }
            }
            .store(in: &cancellables)

        // USB Serial subscriptions (macOS only)
        #if os(macOS) || targetEnvironment(macCatalyst)
        usbManager.receivedDataSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data in
                self?.onFrameReceived?(data)
            }
            .store(in: &cancellables)

        usbManager.receivedLineSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] line in
                self?.onUSBCLILineReceived?(line)
            }
            .store(in: &cancellables)

        usbManager.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                guard let self else { return }
                if connected && self.usbManager.detectedMode == .binary {
                    self.connectionState = .ready
                    self.connectedDeviceName = self.usbManager.connectedPort?.replacingOccurrences(of: "/dev/cu.", with: "")
                }
                if !connected {
                    let previousState = self.connectionState
                    self.connectionState = .disconnected
                    self.connectedDeviceName = nil
                    self.onDisconnected?(previousState)
                }
            }
            .store(in: &cancellables)

        usbManager.$detectedMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                guard let self else { return }
                if mode == .binary && self.usbManager.isConnected {
                    Self.logger.info("USB binary mode detected — initializing device")
                    self.connectionState = .ready
                    self.connectedDeviceName = self.usbManager.connectedPort?.replacingOccurrences(of: "/dev/cu.", with: "")
                    self.onDeviceReady?()
                } else if mode == .cli && self.usbManager.isConnected {
                    Self.logger.info("USB CLI mode detected — initializing management session")
                    self.connectionState = .connected
                    self.connectedDeviceName = "USB: \(self.usbManager.connectedPort?.replacingOccurrences(of: "/dev/cu.", with: "") ?? "Serial")"
                    self.onUSBCLIReady?()
                }
            }
            .store(in: &cancellables)
        #endif
    }
}
