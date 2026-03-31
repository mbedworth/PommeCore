import SwiftUI
import Combine
import os.log
import MeshCoreKit
#if !os(watchOS)
import CoreLocation
#endif

#if !os(watchOS)
/// Shared CLLocationManager — reused across all GPS operations to avoid
/// repeated initialization overhead and redundant hardware activation.
enum SharedLocation {
    static let manager = CLLocationManager()
}
#endif

// MARK: - Radio Config Verification Types

struct RadioConfigVerification: Identifiable {
    let id = UUID()
    let frequency: String
    let bandwidth: String
    let spreadingFactor: Int
    let codingRate: Int
    let txPower: String
    let battery: String
    let firmware: String
    let regionCheck: RegionCheck
    let regionMessage: String
}
enum RegionCheck { case pass, warning, fail }
enum RadioRegion { case americas, europe, japan, india, unknown }

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
    /// Last error message from device — displayed as an alert in ContentView.
    var lastErrorMessage: String?

    /// Radio config verification state.
    var isVerifyingConfig = false
    var lastConfigVerification: RadioConfigVerification?

    // MARK: - Transport Managers

    let bleManager = BLEManager()
    let wifiManager = WiFiConnectionManager()
    #if os(macOS) || targetEnvironment(macCatalyst)
    let usbManager = USBSerialManager()
    #endif


    // MARK: - Dependencies (set by coordinator)

    /// Reference to device config for optimistic UI updates when sending settings commands.
    var deviceConfig: DeviceConfig?

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

    // MARK: - Protocol Convenience Commands

    /// Send a self-advert. If device is sharing location in adverts (advertLocPolicy == 1),
    /// updates the device's coordinates from the phone's GPS first. Applies privacy fudge
    /// if a privacy radius is configured.
    func sendAdvertise(type: UInt8 = 0) {
        #if !os(watchOS)
        if deviceConfig?.advertLocPolicy == 1, let location = SharedLocation.manager.location {
            let radius = UserDefaults.standard.double(forKey: "locationPrivacyRadius")
            if radius > 0 {
                let (fLat, fLon) = MeshCoreViewModel.fudgeLocation(lat: location.coordinate.latitude, lon: location.coordinate.longitude)
                sendCommand(MeshCoreProtocol.buildSetAdvertLatLon(latitude: fLat, longitude: fLon), label: "FUDGE_LATLON")
                DebugLogger.shared.log("ADVERT: fudged GPS applied before advert", level: .tx)
            } else {
                sendCommand(MeshCoreProtocol.buildSetAdvertLatLon(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude), label: "SET_LATLON")
                DebugLogger.shared.log("ADVERT: phone GPS applied before advert", level: .tx)
            }
        }
        #endif
        sendCommand(MeshCoreProtocol.buildSendSelfAdvert(advertType: type), label: "SELF_ADVERT")
    }

    /// Import a contact from a meshcore:// URL string. Sends CMD_IMPORT_CONTACT.
    /// Validates URL format, hex content, and reasonable length before sending to firmware.
    func importContact(url: String) {
        guard url.lowercased().hasPrefix("meshcore://") else {
            Self.logger.warning("IMPORT: rejected — not a meshcore:// URL")
            lastErrorMessage = "Invalid contact link format."
            return
        }
        let hex = String(url.dropFirst("meshcore://".count))
        guard !hex.isEmpty, hex.count <= 512, hex.allSatisfy({ $0.isHexDigit }) else {
            Self.logger.warning("IMPORT: rejected — invalid hex payload (len=\(hex.count))")
            lastErrorMessage = "Invalid contact link data."
            return
        }
        let frame = MeshCoreProtocol.buildImportContact(url: url)
        sendCommand(frame, label: "IMPORT_CONTACT")
    }

    /// Export a contact as a meshcore:// URL. Result arrives as .exportedContact response.
    func exportContact(_ contact: Contact) {
        let keyHex = contact.publicKey.prefix(6).map { String(format: "%02x", $0) }.joined()
        Self.logger.info("EXPORT: requesting export for '\(contact.name)' key=\(keyHex) fullKeyLen=\(contact.publicKey.count)")
        let frame = MeshCoreProtocol.buildExportContact(publicKey: contact.publicKey)
        Self.logger.info("EXPORT: frame=[\(frame.count) bytes] \(frame.map { String(format: "%02x", $0) }.joined(separator: " "))")
        sendCommand(frame, label: "EXPORT_CONTACT")
    }

    /// Export self as a meshcore:// URL (send code byte only, no public key).
    func exportSelfContact() {
        Self.logger.info("EXPORT: requesting self contact export (frame=[1 byte] 11)")
        let frame = Data([0x11])
        sendCommand(frame, label: "EXPORT_SELF")
    }

    // MARK: - Settings Commands

    func setRadioParams(frequency: UInt32, bandwidth: UInt32, spreadingFactor: UInt8, codingRate: UInt8, repeatMode: Bool) {
        sendCommand(MeshCoreProtocol.buildSetRadioParams(
            frequency: frequency, bandwidth: bandwidth,
            spreadingFactor: spreadingFactor, codingRate: codingRate,
            repeatMode: repeatMode
        ), label: "SET_RADIO")
        deviceConfig?.radioFrequency = frequency
        deviceConfig?.radioBandwidth = bandwidth
        deviceConfig?.radioSpreadingFactor = spreadingFactor
        deviceConfig?.radioCodingRate = codingRate
        deviceConfig?.repeatMode = repeatMode
    }

    func setRadioTXPower(_ power: UInt8) {
        sendCommand(MeshCoreProtocol.buildSetRadioTXPower(power), label: "SET_TX_POWER")
        deviceConfig?.radioTXPower = power
    }

    func setTuningParams(rxDelayBase: UInt32, airtimeFactor: UInt32) {
        let frame = MeshCoreProtocol.buildSetTuningParams(rxDelayBase: rxDelayBase, airtimeFactor: airtimeFactor)
        sendCommand(frame, label: "SET_TUNING")
        deviceConfig?.rxDelayBase = rxDelayBase
        deviceConfig?.airtimeFactor = airtimeFactor
        // Read back after firmware processes
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.sendCommand(MeshCoreProtocol.buildGetTuningParams(), label: "GET_TUNING")
        }
    }

    func setOtherParams(manualAddContacts: UInt8, telemetryBase: UInt8, telemetryLocation: UInt8, advertLocPolicy: UInt8, multiACK: UInt8) {
        DebugLogger.shared.log("SET_OTHER_PARAMS: manual=\(manualAddContacts) telBase=\(telemetryBase) telLoc=\(telemetryLocation) advLoc=\(advertLocPolicy) multiACK=\(multiACK)", level: .tx)
        deviceConfig?.manualAddContacts = manualAddContacts
        deviceConfig?.telemetryBase = telemetryBase
        deviceConfig?.telemetryLocation = telemetryLocation
        deviceConfig?.advertLocPolicy = advertLocPolicy
        deviceConfig?.multiACK = multiACK
        sendCommand(MeshCoreProtocol.buildSetOtherParams(
            manualAddContacts: manualAddContacts, telemetryBase: telemetryBase,
            telemetryLocation: telemetryLocation, advertLocPolicy: advertLocPolicy,
            multiACK: multiACK
        ), label: "SET_OTHER_PARAMS")
    }

    func setAdvertName(_ name: String) {
        sendCommand(MeshCoreProtocol.buildSetAdvertName(name), label: "SET_ADVERT_NAME")
        deviceConfig?.deviceName = name
        sendAdvertise()
    }

    func setAdvertLatLon(latitude: Double, longitude: Double) {
        let (fLat, fLon) = MeshCoreViewModel.fudgeLocation(lat: latitude, lon: longitude)
        sendCommand(MeshCoreProtocol.buildSetAdvertLatLon(latitude: fLat, longitude: fLon), label: "SET_LATLON")
        deviceConfig?.latitude = fLat
        deviceConfig?.longitude = fLon
    }

    func setAutoAddConfig(bitmask: UInt8) {
        sendCommand(MeshCoreProtocol.buildSetAutoAddConfig(bitmask: bitmask), label: "SET_AUTOADD(0x\(String(format: "%02x", bitmask)))")
        deviceConfig?.autoAddBitmask = bitmask
    }

    func setDevicePIN(_ pin: UInt32) {
        sendCommand(MeshCoreProtocol.buildSetDevicePIN(pin), label: "SET_PIN")
        deviceConfig?.blePIN = pin
    }

    func setCustomVar(name: String, value: String) {
        sendCommand(MeshCoreProtocol.buildSetCustomVar(name: name, value: value), label: "SET_CUSTOM_VAR")
    }

    func requestCustomVars() {
        sendCommand(MeshCoreProtocol.buildGetCustomVars(), label: "GET_CUSTOM_VARS")
    }

    func requestStats(subType: UInt8) {
        sendCommand(MeshCoreProtocol.buildGetStats(subType: subType), label: "GET_STATS(\(subType))")
    }

    func requestDeviceInfo() {
        sendCommand(MeshCoreProtocol.buildDeviceQuery(), label: "DEVICE_QUERY")
    }

    func requestBattAndStorage() {
        sendCommand(MeshCoreProtocol.buildGetBattAndStorage(), label: "GET_BATT")
    }

    func requestDeviceTime() {
        sendCommand(MeshCoreProtocol.buildGetDeviceTime(), label: "GET_TIME")
    }

    func requestTuningParams() {
        sendCommand(MeshCoreProtocol.buildGetTuningParams(), label: "GET_TUNING")
    }

    func requestAutoAddConfig() {
        sendCommand(MeshCoreProtocol.buildGetAutoAddConfig(), label: "GET_AUTOADD")
    }

    func sendAppStart() {
        sendCommand(MeshCoreProtocol.buildAppStart(), label: "APP_START")
    }

    /// Refresh all device settings by sending all request commands.
    func refreshAllSettings() {
        deviceConfig?.isLoading = true
        deviceConfig?.loadedSections = []
        requestDeviceInfo()
        sendAppStart()
        requestBattAndStorage()
        requestDeviceTime()
        requestTuningParams()
        requestCustomVars()
        requestStats(subType: 0)
        requestStats(subType: 1)
        requestStats(subType: 2)
        requestAutoAddConfig()
    }

    /// Refresh contacts, channels, and all settings.
    func refreshAll(contactStore: ContactStore) {
        guard connectionState == .ready else { return }
        refreshAllSettings()
        contactStore.requestContacts(fullSync: true)
    }

    // MARK: - Radio Config Verification

    func verifyRadioConfig() {
        DebugLogger.shared.log("=== RADIO CONFIG VERIFICATION START ===", level: .info)
        isVerifyingConfig = true
        requestDeviceInfo()
        sendAppStart()
        requestTuningParams()
        requestBattAndStorage()
        requestDeviceTime()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self else { return }
            DebugLogger.shared.log("=== RADIO CONFIG VERIFICATION COMPLETE ===", level: .info)
            self.isVerifyingConfig = false
            self.lastConfigVerification = self.buildConfigVerification()
        }
    }

    private func buildConfigVerification() -> RadioConfigVerification {
        guard let c = deviceConfig else { return RadioConfigVerification(frequency: "?", bandwidth: "?", spreadingFactor: 0, codingRate: 0, txPower: "?", battery: "?", firmware: "?", regionCheck: .warning, regionMessage: "No device config") }
        let freqMHz = Double(c.radioFrequency) / 1000.0
        let bwKHz = Double(c.radioBandwidth) / 1000.0
        let battV = String(format: "%.2fV", Double(c.batteryMillivolts) / 1000.0)
        let battPct = c.batteryPercent()
        let (regionCheck, regionMsg) = checkFrequencyForRegion(freqHz: c.radioFrequency, lat: c.latitude, lon: c.longitude)
        return RadioConfigVerification(
            frequency: String(format: "%.3f MHz", freqMHz),
            bandwidth: String(format: "%.1f kHz", bwKHz),
            spreadingFactor: Int(c.radioSpreadingFactor),
            codingRate: Int(c.radioCodingRate),
            txPower: "\(c.radioTXPower)/\(c.maxTXPower) dBm",
            battery: battPct > 0 ? "\(battV) (\(battPct)%)" : battV,
            firmware: c.semanticVersion.isEmpty ? "v\(c.firmwareVersion)" : c.semanticVersion,
            regionCheck: regionCheck,
            regionMessage: regionMsg
        )
    }

    private func checkFrequencyForRegion(freqHz: UInt32, lat: Double, lon: Double) -> (RegionCheck, String) {
        let freqMHz = Double(freqHz) / 1000.0
        let region = (lat != 0 || lon != 0) ? regionFromCoordinates(lat: lat, lon: lon) : .unknown
        if freqMHz >= 902 && freqMHz <= 928 {
            return region == .europe ? (.fail, "Frequency \(String(format: "%.3f", freqMHz)) MHz is Americas band but GPS shows Europe") :
                (.pass, "Frequency \(String(format: "%.3f", freqMHz)) MHz — Americas band (902-928 MHz)")
        } else if freqMHz >= 863 && freqMHz <= 870 {
            return region == .americas ? (.fail, "Frequency \(String(format: "%.3f", freqMHz)) MHz is EU band but GPS shows Americas") :
                (.pass, "Frequency \(String(format: "%.3f", freqMHz)) MHz — Europe band (863-870 MHz)")
        } else if freqMHz >= 920 && freqMHz <= 928 {
            return (.pass, "Frequency \(String(format: "%.3f", freqMHz)) MHz — Japan band (920-928 MHz)")
        } else if freqMHz >= 865 && freqMHz <= 867 {
            return (.pass, "Frequency \(String(format: "%.3f", freqMHz)) MHz — India band (865-867 MHz)")
        }
        return (.warning, "Frequency \(String(format: "%.3f", freqMHz)) MHz — verify manually for your region")
    }

    private func regionFromCoordinates(lat: Double, lon: Double) -> RadioRegion {
        if lat >= -60 && lat <= 72 && lon >= -170 && lon <= -30 { return .americas }
        if lat >= -48 && lat <= -10 && lon >= 110 && lon <= 180 { return .americas }
        if lat >= 35 && lat <= 72 && lon >= -10 && lon <= 40 { return .europe }
        if lat >= 24 && lat <= 46 && lon >= 122 && lon <= 154 { return .japan }
        if lat >= 6 && lat <= 36 && lon >= 68 && lon <= 98 { return .india }
        return .unknown
    }

    // MARK: - Phone GPS Auto-Update

    private var locationUpdateTimer: Timer?

    func startAutoLocationUpdates(interval: Int) {
        locationUpdateTimer?.invalidate()
        setLocationFromPhoneGPS()
        locationUpdateTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(interval), repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.setLocationFromPhoneGPS()
            }
        }
        DebugLogger.shared.log("PHONE GPS: auto-update every \(interval / 60)min", level: .info)
    }

    func stopAutoLocationUpdates() {
        locationUpdateTimer?.invalidate()
        locationUpdateTimer = nil
        DebugLogger.shared.log("PHONE GPS: auto-update stopped", level: .info)
    }

    private func setLocationFromPhoneGPS() {
        #if !os(watchOS)
        guard let location = SharedLocation.manager.location else { return }
        let (fLat, fLon) = MeshCoreViewModel.fudgeLocation(lat: location.coordinate.latitude, lon: location.coordinate.longitude)
        setAdvertLatLon(latitude: fLat, longitude: fLon)
        #endif
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
        stopScanning()
        connectionState = .connecting
        connectedDeviceName = port.replacingOccurrences(of: "/dev/cu.", with: "")
        usbManager.connect(to: port)
    }

    func disconnectUSB() {
        usbManager.disconnect()
        if connectionState != .disconnected {
            connectionState = .disconnected
            connectedDeviceName = nil
        }
        // Show scanner after USB disconnect so user can reconnect
        DebugLogger.shared.log("USB: disconnected — showing scanner in 2s", level: .info)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.connectionState == .disconnected else { return }
            self.requestShowScanner = true
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
