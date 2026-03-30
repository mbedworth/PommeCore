import SwiftUI
import Combine
import os.log
import UserNotifications
#if os(watchOS)
import WatchKit
#endif
import MeshCoreKit
#if !os(watchOS)
import CoreLocation
import CryptoKit
#endif
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif

#if os(macOS) || targetEnvironment(macCatalyst)
/// A line of output in the USB serial terminal.
struct USBTerminalLine: Identifiable {
    let id = UUID()
    let text: String
    let isCommand: Bool
}
#endif

/// Whether iCloud sync is enabled (stored locally per device, defaults to true).
var iCloudSyncEnabled: Bool {
    UserDefaults.standard.object(forKey: "iCloudSyncEnabled") == nil ? true : UserDefaults.standard.bool(forKey: "iCloudSyncEnabled")
}

// RadioConfigVerification, RegionCheck, RadioRegion moved to ConnectionManager

/// Notification preferences synced via iCloud key-value store (when enabled).
@MainActor
final class NotificationPreferences: ObservableObject {
    static let shared = NotificationPreferences()
    private let store = NSUbiquitousKeyValueStore.default

    @Published var notifyDirect: Bool {
        didSet { store.set(notifyDirect, forKey: "notify.direct"); store.synchronize() }
    }
    @Published var notifyChannel: Bool {
        didSet { store.set(notifyChannel, forKey: "notify.channel"); store.synchronize() }
    }
    @Published var notifyRoom: Bool {
        didSet { store.set(notifyRoom, forKey: "notify.room"); store.synchronize() }
    }
    @Published var notifyNewContacts: Bool {
        didSet { store.set(notifyNewContacts, forKey: "notify.newContacts"); store.synchronize() }
    }
    @Published var notifyConnection: Bool {
        didSet { store.set(notifyConnection, forKey: "notify.connection"); store.synchronize() }
    }

    private init() {
        // Load with defaults (true for messages, false for new contacts)
        notifyDirect = store.object(forKey: "notify.direct") == nil ? true : store.bool(forKey: "notify.direct")
        notifyChannel = store.object(forKey: "notify.channel") == nil ? true : store.bool(forKey: "notify.channel")
        notifyRoom = store.object(forKey: "notify.room") == nil ? true : store.bool(forKey: "notify.room")
        notifyNewContacts = store.bool(forKey: "notify.newContacts")
        notifyConnection = store.object(forKey: "notify.connection") == nil ? true : store.bool(forKey: "notify.connection")

        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.loadAll()
            }
        }
    }

    private func loadAll() {
        notifyDirect = store.object(forKey: "notify.direct") == nil ? true : store.bool(forKey: "notify.direct")
        notifyChannel = store.object(forKey: "notify.channel") == nil ? true : store.bool(forKey: "notify.channel")
        notifyRoom = store.object(forKey: "notify.room") == nil ? true : store.bool(forKey: "notify.room")
        notifyNewContacts = store.bool(forKey: "notify.newContacts")
        notifyConnection = store.object(forKey: "notify.connection") == nil ? true : store.bool(forKey: "notify.connection")
    }
}

/// Unified sidebar selection for NavigationSplitView.
// SidebarSelection enum moved to NavigationStore.swift

@MainActor
final class MeshCoreViewModel: ObservableObject {
    private static let logger = Logger(subsystem: "com.meshcore", category: "ViewModel")

    // MARK: - Stores (Phase 1-5 of @Observable refactor)
    // Stores own state and logic. ViewModel forwards public API during migration.
    // Views still use @EnvironmentObject var viewModel — Phase 7 switches to @Environment(Store.self).

    let contactStore = ContactStore()
    let channelStore = ChannelStore()
    let messageStoreManager = MessageStoreManager()
    let connectionManager = ConnectionManager()
    let remoteSessionManager = RemoteSessionManager()
    let navigationStore = NavigationStore()

    // MARK: - Forwarded State (computed, delegates to stores)
    // These replace the old @Published properties. The bridge in observeStores()
    // fires objectWillChange when any store property changes.

    var contacts: [Contact] {
        get { contactStore.contacts }
        set { contactStore.contacts = newValue }
    }

    // pendingNewContacts, contactGroups removed — views use ContactStore directly

    var channels: [MeshChannel] {
        get { channelStore.channels }
        set { channelStore.channels = newValue }
    }

    // isSyncingChannels removed — views use ChannelStore directly

    // messagesByContact, unreadCounts, lastExportedURL, sidebarSelection removed — use stores directly

    // MARK: - Internet Map (non-watchOS only)
    #if !os(watchOS)
    private var pendingMapUpload = false
    private var pendingMapDataJSON: String?
    #endif



    // isScanning, discoveredPeripherals removed — views use ConnectionManager directly
    var connectionState: BLEConnectionState {
        get { connectionManager.connectionState }
        set { connectionManager.connectionState = newValue }
    }
    // connectedDeviceName removed — use connectionManager.connectedDeviceName directly
    /// Device configuration — @Observable (fine-grained tracking).
    /// Not @Published: the observeStores bridge tracks changes via @Observable.
    /// Reference is replaced (= DeviceConfig()) on disconnect to reset all state.
    var deviceConfig = DeviceConfig()

    // messagesByContact, unreadCounts -> forwarded from messageStoreManager (computed above)

    // MARK: - Contact Nicknames — forwarded to ContactStore

    private let iCloudStore = NSUbiquitousKeyValueStore.default

    private func registerTerminationHandler() {
        #if os(iOS)
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.bleManager.disconnectForTermination()
            }
        }
        #elseif os(macOS)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.bleManager.disconnectForTermination()
            }
        }
        #endif
    }

    private func observeiCloudChanges() {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: iCloudStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // ContactStore handles its own iCloud observation for nicknames/notes/groups
                self?.mergeMessagesForCurrentRadio()
            }
        }
    }

    // MARK: - Forwarding: Nicknames/DisplayName/Activity → ContactStore

    func displayName(for contact: Contact) -> String { contactStore.displayName(for: contact) }

    // Battery calibration moved to DeviceConfig

    // MARK: - Forwarding: Spotlight → ContactStore

    #if canImport(CoreSpotlight)
    // indexContactsForSpotlight removed — called directly on contactStore

    func navigateToContact(pubkeyHex: String) {
        if let contact = contacts.first(where: {
            $0.publicKey.map { String(format: "%02x", $0) }.joined() == pubkeyHex
        }) {
            navigationStore.sidebarSelection = .contact(contact.publicKeyPrefix)
        }
    }
    #endif

    /// Last error message received from the device (shown as alert).
    // lastErrorMessage moved to ConnectionManager

    /// BLE status message — forwarded from ConnectionManager.
    var bleStatusMessage: String? {
        get { connectionManager.bleStatusMessage }
        set { connectionManager.bleStatusMessage = newValue }
    }

    // Transport managers — forwarded from ConnectionManager
    var bleManager: BLEManager { connectionManager.bleManager }
    var wifiManager: WiFiConnectionManager { connectionManager.wifiManager }
    #if os(macOS) || targetEnvironment(macCatalyst)
    var usbManager: USBSerialManager { connectionManager.usbManager }
    var usbCLIOutput: [USBTerminalLine] {
        get { remoteSessionManager.usbCLIOutput }
        set { remoteSessionManager.usbCLIOutput = newValue }
    }
    var usbDeviceSession: RemoteDeviceSession? {
        get { remoteSessionManager.usbDeviceSession }
        set { remoteSessionManager.usbDeviceSession = newValue }
    }
    var usbDeviceContact: Contact? {
        get { remoteSessionManager.usbDeviceContact }
        set { remoteSessionManager.usbDeviceContact = newValue }
    }
    var isUSBCLIConnected: Bool {
        connectionManager.isUSBCLIMode && remoteSessionManager.isUSBCLIConnected
    }
    #endif
    private var cancellables = Set<AnyCancellable>()
    // messageStore, pendingACKs, pendingChannelEcho, isSyncingMessages -> moved to MessageStoreManager
    // pendingAutoScan, scanRetryCount, maxScanRetries, scanRetryTask -> moved to ConnectionManager

    /// Scan retry count — forwarded from ConnectionManager.
    var scanRetryCount: Int {
        get { connectionManager.scanRetryCount }
        set { connectionManager.scanRetryCount = newValue }
    }

    /// Whether the app is currently in the background (for local notifications).
    var isInBackground: Bool {
        get { connectionManager.isInBackground }
        set { connectionManager.isInBackground = newValue }
    }

    // Login, timeouts, network tools state -> moved to RemoteSessionManager
    // contactSyncDebounceTask -> moved to ContactStore

    // Network tools — forwarded from RemoteSessionManager
    var discoveredNodes: [DiscoveredNode] {
        get { remoteSessionManager.discoveredNodes }
        set { remoteSessionManager.discoveredNodes = newValue }
    }
    var isDiscovering: Bool {
        get { remoteSessionManager.isDiscovering }
        set { remoteSessionManager.isDiscovering = newValue }
    }
    var discoverFallbackMessage: String? {
        get { remoteSessionManager.discoverFallbackMessage }
        set { remoteSessionManager.discoverFallbackMessage = newValue }
    }
    var lastTraceResult: TraceResult? {
        get { remoteSessionManager.lastTraceResult }
        set { remoteSessionManager.lastTraceResult = newValue }
    }
    var telemetryByContact: [Data: [TelemetryReading]] {
        get { remoteSessionManager.telemetryByContact }
        set { remoteSessionManager.telemetryByContact = newValue }
    }
    var statusByContact: [Data: RemoteStatusInfo] {
        get { remoteSessionManager.statusByContact }
        set { remoteSessionManager.statusByContact = newValue }
    }
    var advertPathByContact: [Data: AdvertPathInfo] {
        get { remoteSessionManager.advertPathByContact }
        set { remoteSessionManager.advertPathByContact = newValue }
    }
    var allowedRepeatFreqRanges: [FrequencyRange] {
        get { remoteSessionManager.allowedRepeatFreqRanges }
        set { remoteSessionManager.allowedRepeatFreqRanges = newValue }
    }
    var pendingTraceTag: UInt32? { remoteSessionManager.pendingTraceTag }
    var detailContactForTrace: Contact? {
        get { remoteSessionManager.detailContactForTrace }
        set { remoteSessionManager.detailContactForTrace = newValue }
    }
    var pendingAdvertPathKey: Data? { remoteSessionManager.pendingAdvertPathKey }
    var pendingStatusKey: Data? { remoteSessionManager.pendingStatusKey }
    var pendingTelemetryKey: Data? { remoteSessionManager.pendingTelemetryKey }

    init() {
        wireStoreDependencies()
        wireConnectionCallbacks()
        observeStores()
        requestNotificationPermissions()
        observeiCloudChanges()
        registerTerminationHandler()
    }

    /// Wire cross-store dependencies via closures (no circular references).
    private func wireStoreDependencies() {
        // ContactStore dependencies
        contactStore.sendCommand = { [weak self] data, label in self?.connectionManager.sendCommand(data, label: label) }
        contactStore.activityDateProvider = { [weak self] key in self?.messageStoreManager.latestActivityDate(for: key) }
        contactStore.postEventNotification = { [weak self] title, body, threadId in self?.postEventNotification(title: title, body: body, threadId: threadId) }
        contactStore.radioPublicKeyHexProvider = { [weak self] in self?.deviceConfig.publicKeyHex ?? "" }

        // ChannelStore dependencies
        channelStore.sendCommand = { [weak self] data, label in self?.connectionManager.sendCommand(data, label: label) }
        channelStore.clearChannelMessages = { [weak self] key in
            self?.messageStoreManager.messagesByContact.removeValue(forKey: key)
            self?.messageStoreManager.unreadCounts.removeValue(forKey: key)
        }
        channelStore.persistChannelMessages = { [weak self] key in self?.messageStoreManager.persistMessages(for: key) }

        // MessageStoreManager dependencies
        messageStoreManager.sendCommand = { [weak self] data, label in self?.connectionManager.sendCommand(data, label: label) }
        messageStoreManager.displayNameProvider = { [weak self] key in
            guard let self, let contact = self.contacts.first(where: { $0.publicKeyPrefix == key }) else { return "Unknown" }
            return self.displayName(for: contact)
        }
        messageStoreManager.deviceNameProvider = { [weak self] in self?.deviceConfig.deviceName ?? "" }
        messageStoreManager.radioPublicKeyHexProvider = { [weak self] in self?.deviceConfig.publicKeyHex ?? "" }
        messageStoreManager.contactProvider = { [weak self] key in self?.contacts.first(where: { $0.publicKeyPrefix == key }) }
        messageStoreManager.channelProvider = { [weak self] idx in self?.channels.first(where: { $0.index == idx }) }
        messageStoreManager.channelNotifyModeProvider = { [weak self] name in self?.channelStore.channelNotifyMode(for: name) ?? .all }
        messageStoreManager.allChannelsProvider = { [weak self] in self?.channels ?? [] }
        messageStoreManager.resetPathForContact = { [weak self] contact in self?.contactStore.resetPath(for: contact) }

        // RemoteSessionManager dependencies
        remoteSessionManager.sendCommand = { [weak self] data, label in self?.connectionManager.sendCommand(data, label: label) }
        remoteSessionManager.contactsProvider = { [weak self] in self?.contacts ?? [] }
        remoteSessionManager.deviceConfigProvider = { [weak self] in self?.deviceConfig ?? DeviceConfig() }
        remoteSessionManager.syncNextMessage = { [weak self] in self?.syncNextMessage() }
        remoteSessionManager.showError = { [weak self] msg in self?.connectionManager.lastErrorMessage = msg }
        remoteSessionManager.onStateChanged = { [weak self] in self?.objectWillChange.send() }
        #if os(macOS) || targetEnvironment(macCatalyst)
        remoteSessionManager.sendUSBCLI = { [weak self] cmd in self?.connectionManager.sendUSBCLI(cmd) }
        #endif
    }

    /// Wire ConnectionManager callbacks for frame dispatch and lifecycle events.
    private func wireConnectionCallbacks() {
        connectionManager.deviceConfig = deviceConfig
        connectionManager.onFrameReceived = { [weak self] data in
            self?.handleReceivedData(data)
        }
        connectionManager.onDeviceReady = { [weak self] in
            self?.onDeviceReady()
        }
        connectionManager.onUSBCLIReady = { [weak self] in
            #if os(macOS) || targetEnvironment(macCatalyst)
            self?.onUSBCLIReady()
            #endif
        }
        connectionManager.onDisconnected = { [weak self] previousState in
            self?.handleDisconnect(previousState: previousState)
        }
        #if os(macOS) || targetEnvironment(macCatalyst)
        connectionManager.onUSBCLILineReceived = { [weak self] line in
            self?.remoteSessionManager.handleUSBCLILine(line)
        }
        #endif
    }

    /// Handle disconnect cleanup — called by ConnectionManager when state → disconnected.
    private func handleDisconnect(previousState: BLEConnectionState) {
        remoteSessionManager.resetLoginSessions()
        remoteSessionManager.reset()
        self.stopAutoLocationUpdates()
        self.deviceConfig.reset()
        self.contactStore.reset()
        self.channelStore.reset()
        self.messageStoreManager.markAllSendingAsFailed()
        self.messageStoreManager.reset()
        self.messageStoreManager.deactivate()

        // Connection loss notification
        if previousState == .connecting || previousState == .ready {
            if self.isInBackground && NotificationPreferences.shared.notifyConnection {
                let deviceName = self.connectionManager.connectedDeviceName ?? "radio"
                self.postEventNotification(
                    title: "Connection Lost",
                    body: "Lost connection to \(deviceName). Attempting to reconnect...",
                    threadId: "connection"
                )
            }
        }
    }

    /// Bridge @Observable stores → ObservableObject ViewModel.
    /// Re-registers withObservationTracking so that any store property
    /// change fires objectWillChange on the ViewModel. Views using
    /// @EnvironmentObject continue to work during migration.
    /// True while we are inside objectWillChange.send() to prevent re-entrant cascades.
    private var isSendingChange = false

    private func observeStores() {
        func trackChanges() {
            withObservationTracking {
                // Only track properties still read by views via @EnvironmentObject viewModel.
                // Views migrated to @Environment(Store.self) observe stores directly.
                // MeshCoreApp reads: contacts, channels, connectionState, requestShowScanner
                // SettingsView reads: batteryCalibration (@Published, not tracked here)
                _ = self.contactStore.contacts
                _ = self.channelStore.channels
                _ = self.connectionManager.connectionState
                _ = self.connectionManager.requestShowScanner
            } onChange: {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                    guard let self, !self.isSendingChange else {
                        // Re-register tracking even if we skip the send
                        trackChanges()
                        return
                    }
                    self.isSendingChange = true
                    self.objectWillChange.send()
                    self.isSendingChange = false
                    trackChanges()
                }
            }
        }
        trackChanges()
    }

    private func persistMessages(for contactKeyHash: Data) {
        messageStoreManager.persistMessages(for: contactKeyHash)
    }

    func mergeMessagesForCurrentRadio() {
        messageStoreManager.mergeMessagesForCurrentRadio()
    }

    /// Request notification permissions on first launch.
    private func requestNotificationPermissions() {
        let log = Self.logger
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                log.warning("Notification permission error: \(error.localizedDescription)")
            } else {
                log.info("Notification permission granted: \(granted)")
            }
        }
        setupNotificationCategories()
    }

    private func setupNotificationCategories() {
        #if os(iOS)
        let replyAction = UNTextInputNotificationAction(
            identifier: "REPLY_ACTION",
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Type a message..."
        )
        let messageCategory = UNNotificationCategory(
            identifier: "MESSAGE_CATEGORY",
            actions: [replyAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([messageCategory])
        #endif
    }

    /// Handle a quick reply from a notification action.
    func handleNotificationReply(text: String, contactPubkeyHex: String) {
        guard let contact = contacts.first(where: {
            $0.publicKey.map { String(format: "%02x", $0) }.joined() == contactPubkeyHex
        }) else {
            Self.logger.warning("Quick reply: contact not found for \(contactPubkeyHex)")
            return
        }
        messageStoreManager.sendTextMessage(text, to: contact)
    }

    // postLocalNotification, updateAppBadge, playHapticFeedback, playReceiveHaptic -> MessageStoreManager

    private func postEventNotification(title: String, body: String, threadId: String = "system") {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = threadId
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // updateAppBadge removed — views use MessageStoreManager directly

    // setupSubscriptions removed — transport subscriptions moved to ConnectionManager.
    // ConnectionManager callbacks are wired in wireConnectionCallbacks().

    private func onDeviceReady() {
        #if os(macOS) || targetEnvironment(macCatalyst)
        // USB CLI mode handles its own settings fetch — don't send binary commands
        if usbManager.isConnected && usbManager.detectedMode == .cli { return }
        #endif
        // Reconnection notification
        if isInBackground && NotificationPreferences.shared.notifyConnection {
            postEventNotification(
                title: "Reconnected",
                body: "Connected to \(connectionManager.connectedDeviceName ?? "radio")",
                threadId: "connection"
            )
        }
        channelStore.hasCompletedInitialChannelSync = false
        refreshAllSettings()
        requestContacts(fullSync: true)
        syncNextMessage()
    }

    func refreshAll() {
        connectionManager.refreshAll(contactStore: contactStore)
    }

    // Scanning & connection forwards removed — views use ConnectionManager directly

    #if os(macOS) || targetEnvironment(macCatalyst)
    /// Called when USB CLI mode is detected — delegates to RemoteSessionManager.
    private func onUSBCLIReady() {
        let portName = usbManager.connectedPort?.replacingOccurrences(of: "/dev/cu.", with: "") ?? "USB Device"
        remoteSessionManager.onUSBCLIReady(portName: portName) { [weak self] cmd in
            self?.connectionManager.sendUSBCLI(cmd)
        }
        // Set ready state after clock sync
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self else { return }
            self.connectionManager.connectionState = .ready
            DebugLogger.shared.log("USB CLI: connectionState set to .ready, isUSBCLIConnected=\(self.isUSBCLIConnected)", level: .info)
        }
    }
    #endif

    // disconnect, disconnectUSB, sendUSBCLI removed — views use stores directly

    // MARK: - Protocol Commands

    // sendCommand routing moved to ConnectionManager.
    // ViewModel calls connectionManager.sendCommand directly.
    private func sendCommand(_ data: Data, label: String) {
        connectionManager.sendCommand(data, label: label)
    }

    func sendAppStart() { connectionManager.sendAppStart() }
    func requestDeviceInfo() { connectionManager.requestDeviceInfo() }

    // verifyRadioConfig, buildConfigVerification, checkFrequencyForRegion moved to ConnectionManager

    private func requestDebouncedIncrementalSync() { contactStore.requestDebouncedIncrementalSync() }
    func requestContacts(fullSync: Bool = false) { contactStore.requestContacts(fullSync: fullSync) }

    // sendAdvertise removed — views use ConnectionManager directly

    func requestBattAndStorage() { connectionManager.requestBattAndStorage() }
    func requestDeviceTime() { connectionManager.requestDeviceTime() }
    func requestTuningParams() { connectionManager.requestTuningParams() }

    func requestCustomVars() { connectionManager.requestCustomVars() }
    func requestStats(subType: UInt8) { connectionManager.requestStats(subType: subType) }
    func requestAutoAddConfig() { connectionManager.requestAutoAddConfig()
    }

    func setAutoAddConfig(bitmask: UInt8) {
        sendCommand(MeshCoreProtocol.buildSetAutoAddConfig(bitmask: bitmask), label: "SET_AUTOADD(0x\(String(format: "%02x", bitmask)))")
        deviceConfig.autoAddBitmask = bitmask
    }

    func refreshAllSettings() {
        connectionManager.refreshAllSettings()
    }

    // MARK: - Settings Commands

    func setAdvertName(_ name: String) { connectionManager.setAdvertName(name) }

    func setAdvertLatLon(latitude: Double, longitude: Double) {
        connectionManager.setAdvertLatLon(latitude: latitude, longitude: longitude)
    }

    /// Session-stable random offset for location privacy. Regenerated on app launch
    /// or when the privacy radius setting changes.
    private static var locationFudgeAngle: Double = Double.random(in: 0..<(2 * .pi))
    private static var locationFudgeFraction: Double = Double.random(in: 0...1)

    /// Apply a privacy offset to coordinates. The offset is consistent within a session.
    static func fudgeLocation(lat: Double, lon: Double) -> (Double, Double) {
        let radius = UserDefaults.standard.double(forKey: "locationPrivacyRadius")
        guard radius > 0 else { return (lat, lon) }

        let distance = Self.locationFudgeFraction * radius
        let latOffset = (distance * cos(Self.locationFudgeAngle)) / 111_320.0
        let lonOffset = (distance * sin(Self.locationFudgeAngle)) / (111_320.0 * cos(lat * .pi / 180))
        return (lat + latOffset, lon + lonOffset)
    }

    /// Regenerate the location fudge offset (called when privacy radius changes).
    static func regenerateLocationFudge() {
        locationFudgeAngle = Double.random(in: 0..<(2 * .pi))
        locationFudgeFraction = Double.random(in: 0...1)
    }

    // MARK: - Phone GPS Auto-Update

    private var locationUpdateTimer: Timer?

    /// Start periodically syncing phone GPS to the radio.
    func startAutoLocationUpdates(interval: Int) { connectionManager.startAutoLocationUpdates(interval: interval) }
    func stopAutoLocationUpdates() { connectionManager.stopAutoLocationUpdates() }

    func setRadioParams(frequency: UInt32, bandwidth: UInt32, spreadingFactor: UInt8, codingRate: UInt8, repeatMode: Bool) {
        connectionManager.setRadioParams(frequency: frequency, bandwidth: bandwidth, spreadingFactor: spreadingFactor, codingRate: codingRate, repeatMode: repeatMode)
    }

    func setRadioTXPower(_ power: UInt8) { connectionManager.setRadioTXPower(power) }

    func setTuningParams(rxDelayBase: UInt32, airtimeFactor: UInt32) {
        connectionManager.setTuningParams(rxDelayBase: rxDelayBase, airtimeFactor: airtimeFactor)
    }

    func setOtherParams(manualAddContacts: UInt8, telemetryBase: UInt8, telemetryLocation: UInt8, advertLocPolicy: UInt8, multiACK: UInt8) {
        connectionManager.setOtherParams(manualAddContacts: manualAddContacts, telemetryBase: telemetryBase, telemetryLocation: telemetryLocation, advertLocPolicy: advertLocPolicy, multiACK: multiACK)
    }

    func setDevicePIN(_ pin: UInt32) { connectionManager.setDevicePIN(pin) }

    func setDeviceTime(epochSeconds: UInt32) {
        sendCommand(MeshCoreProtocol.buildSetDeviceTime(epochSeconds: epochSeconds), label: "SET_TIME")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.requestDeviceTime()
        }
    }

    func setCustomVar(name: String, value: String) { connectionManager.setCustomVar(name: name, value: value) }

    func rebootDevice() {
        sendCommand(MeshCoreProtocol.buildReboot(), label: "REBOOT")
    }

    func factoryReset() {
        sendCommand(MeshCoreProtocol.buildFactoryReset(), label: "FACTORY_RESET")
    }

    // MARK: - Forwarding: Contact Management → ContactStore

    func removeContact(_ contact: Contact) {
        contactStore.removeContact(contact)
        messageStoreManager.messagesByContact.removeValue(forKey: contact.publicKeyPrefix)
        messageStoreManager.unreadCounts.removeValue(forKey: contact.publicKeyPrefix)
        if case .contact(let key) = navigationStore.sidebarSelection, key == contact.publicKeyPrefix {
            navigationStore.sidebarSelection = nil
        }
    }

    // resetPath, shareContact removed — views use stores directly

    /// Export a contact as a meshcore:// URL. Result arrives as .exportedContact response.
    func exportContact(_ contact: Contact) {
        messageStoreManager.lastExportedURL = nil
        connectionManager.exportContact(contact)
    }

    func exportSelfContact() {
        messageStoreManager.lastExportedURL = nil
        connectionManager.exportSelfContact()
    }

    // MARK: - Internet Map
    // Note: internetMapNodes/fetchInternetMapNodes moved to MeshMapView @State (view-local).

    /// Import a contact from a meshcore:// URL string. Sends CMD_IMPORT_CONTACT.
    /// The device will send contact data frames in response — no need to re-sync.
    func importContact(url: String) {
        let frame = MeshCoreProtocol.buildImportContact(url: url)
        sendCommand(frame, label: "IMPORT_CONTACT")
        // Refresh contacts after a short delay to pick up the new import
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.requestContacts(fullSync: true)
        }
    }

    // lastExportedURL -> forwarded from messageStoreManager (computed above)

    func handleMeshCoreURL(_ urlString: String) {
        if channelStore.handleChannelURL(urlString) { return }
        if urlString.hasPrefix("meshcore://") {
            importContact(url: urlString)
        }
    }

    // Channel import / messaging forwards removed — views use stores directly

    func syncNextMessage() {
        #if os(macOS) || targetEnvironment(macCatalyst)
        guard !isUSBCLIConnected else { return }
        #endif
        messageStoreManager.syncNextMessage()
    }

    // Remote management forwards removed — views use RemoteSessionManager directly

    // MARK: - Response Handling

    /// Routine response codes that don't need hex dumps in the in-app debug log.
    private static let routineResponseCodes: Set<UInt8> = [
        0x00, // OK
        0x02, // contactsStart
        0x03, // contact
        0x04, // endOfContacts
        0x09, // currTime
        0x0A, // noMoreMessages
        0x0C, // battAndStorage
        0x12, // channelInfo
        0x17, // tuningParams
        0x18, // stats
        0x19, // autoAddConfig
        0x80, // advert
        0x81, // pathUpdated
        0x83, // msgWaiting
        0x88, // logRxData
    ]

    private func handleReceivedData(_ data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        Self.logger.info("RX [\(data.count)]: \(hex)")
        // Only log hex to in-app debug log for non-routine frames
        let code = data.first ?? 0
        if !Self.routineResponseCodes.contains(code) {
            DebugLogger.shared.log("RX [\(data.count)B] \(hex)", level: .rx)
        }

        let response = FrameParser.parse(data)

        switch response {
        case .ok:
            Self.logger.info("RESP OK — last command accepted by device")

        case .error(let code, let description):
            Self.logger.warning("Error response: code=\(code) \(description)")
            DebugLogger.shared.log("RESP ERR code=\(code) \(description)", level: .error)
            handleErrorResponse(code: code, description: description)

        case .selfInfo(let info):
            Self.logger.info("PARSED SelfInfo: name='\(info.name)' txPwr=\(info.txPower)/\(info.maxTXPower) freq=\(info.radioFreq) bw=\(info.radioBW) sf=\(info.radioSF) cr=\(info.radioCR) lat=\(info.latitude) lon=\(info.longitude)")
            let freqMHz = String(format: "%.3f", Double(info.radioFreq) / 1000.0)
            let bwKHz = String(format: "%.1f", Double(info.radioBW) / 1000.0)
            let keyHex = info.publicKey.prefix(8).map { String(format: "%02x", $0) }.joined()
            DebugLogger.shared.log("RADIO: freq=\(freqMHz)MHz BW=\(bwKHz)kHz SF=\(info.radioSF) CR=\(info.radioCR) TX=\(info.txPower)/\(info.maxTXPower)dBm", level: .rx)
            DebugLogger.shared.log("RADIO: name='\(info.name)' type=\(info.type) pubkey=\(keyHex)...", level: .rx)
            DebugLogger.shared.log("RADIO: lat=\(info.latitude) lon=\(info.longitude) multiACK=\(info.multiACK) advLoc=\(info.advertLocPolicy)", level: .rx)
            deviceConfig.deviceName = info.name
            deviceConfig.selfType = info.type
            deviceConfig.radioTXPower = info.txPower
            deviceConfig.maxTXPower = info.maxTXPower
            deviceConfig.publicKeyHex = info.publicKey.map { String(format: "%02x", $0) }.joined()
            deviceConfig.loadBatteryCalibration()
            let radioPrefix = String(deviceConfig.publicKeyHex.prefix(12))
            messageStoreManager.activateForRadio(radioPrefix)
            channelStore.activateForRadio(radioPrefix)
            // Reload nicknames/notes for this specific radio
            contactStore.loadNicknamesFromiCloud()
            contactStore.loadContactNotesFromiCloud()
            deviceConfig.latitude = info.latitude
            deviceConfig.longitude = info.longitude
            deviceConfig.radioFrequency = info.radioFreq
            deviceConfig.radioBandwidth = info.radioBW
            deviceConfig.radioSpreadingFactor = info.radioSF
            deviceConfig.radioCodingRate = info.radioCR
            deviceConfig.manualAddContacts = info.manualAddContacts
            deviceConfig.telemetryBase = info.telemetryByte & 0x03
            deviceConfig.telemetryLocation = (info.telemetryByte >> 2) & 0x03
            deviceConfig.advertLocPolicy = info.advertLocPolicy
            deviceConfig.multiACK = info.multiACK
            deviceConfig.loadedSections.insert("selfInfo")
            checkLoadingComplete()

            // Auto-sync device clock on every connection
            let epoch = UInt32(Date().timeIntervalSince1970)
            sendCommand(MeshCoreProtocol.buildSetDeviceTime(epochSeconds: epoch), label: "SET_TIME(auto)")
            DebugLogger.shared.log("CLOCK: auto-synced device time to \(epoch)", level: .info)

            // Trigger map upload if opt-in is enabled and the node has a location.
            // The device coordinates already have the GPS fudge applied (all writes
            // go through setAdvertLatLon → fudgeLocation before reaching the device).
            #if !os(watchOS)
            let mapOptIn = UserDefaults.standard.bool(forKey: "shareOnMeshMap")
            let hasLocation = info.latitude != 0 || info.longitude != 0
            if mapOptIn, hasLocation {
                pendingMapUpload = true
                sendCommand(Data([0x11]), label: "EXPORT_SELF(map)")
                DebugLogger.shared.log("MAP: triggered self-export for upload", level: .info)
            }
            #endif

        case .deviceInfo(let info):
            Self.logger.info("PARSED DeviceInfo: fwVer=\(info.firmwareVersion) buildDate='\(info.buildDate)' mfg='\(info.manufacturer)' semVer='\(info.semanticVersion)' blePIN=\(info.blePIN)")
            DebugLogger.shared.log("DEVICE: fw=\(info.firmwareVersion) ver='\(info.semanticVersion)' build='\(info.buildDate)'", level: .rx)
            DebugLogger.shared.log("DEVICE: mfg='\(info.manufacturer)' maxContacts=\(Int(info.maxContactsDiv2) * 2) maxCh=\(info.maxChannels) PIN=\(info.blePIN)", level: .rx)
            deviceConfig.firmwareVersion = String(info.firmwareVersion)
            deviceConfig.buildDate = info.buildDate
            deviceConfig.manufacturer = info.manufacturer
            deviceConfig.semanticVersion = info.semanticVersion
            deviceConfig.blePIN = info.blePIN
            deviceConfig.maxContacts = UInt16(info.maxContactsDiv2) * 2
            deviceConfig.maxChannels = info.maxChannels
            deviceConfig.loadedSections.insert("deviceInfo")
            checkLoadingComplete()

        case .battAndStorage(let info):
            Self.logger.info("PARSED BattAndStorage: \(info.batteryMV) mV")
            deviceConfig.batteryMillivolts = info.batteryMV
            let chemRaw = UserDefaults.standard.string(forKey: "batteryChemistry") ?? BatteryChemistry.lipo.rawValue
            let chem = BatteryChemistry(rawValue: chemRaw) ?? .lipo
            deviceConfig.updateBatteryCalibration(rawMillivolts: info.batteryMV, chemistry: chem)
            deviceConfig.loadedSections.insert("battAndStorage")
            checkLoadingComplete()

        case .currentTime(let epoch):
            Self.logger.info("PARSED Time: epoch=\(epoch)")
            deviceConfig.deviceTimeEpoch = epoch
            deviceConfig.loadedSections.insert("time")
            checkLoadingComplete()

        case .tuningParams(let rxDelay, let airtime):
            Self.logger.info("PARSED Tuning: rxDelay=\(rxDelay) airtime=\(airtime)")
            let rxSec = String(format: "%.1f", Double(rxDelay) / 1000.0)
            let atFactor = String(format: "%.1f", Double(airtime) / 1000.0)
            DebugLogger.shared.log("TUNING: rxDelay=\(rxSec)s airtime=\(atFactor)x (raw: \(rxDelay), \(airtime))", level: .rx)
            deviceConfig.rxDelayBase = rxDelay
            deviceConfig.airtimeFactor = airtime
            deviceConfig.loadedSections.insert("tuning")
            checkLoadingComplete()

        case .customVars(let str):
            Self.logger.info("PARSED CustomVars: '\(str)'")
            let pairs = str.split(separator: ",").compactMap { pair -> (String, String)? in
                let parts = pair.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return (String(parts[0]), String(parts[1]))
            }
            deviceConfig.customVars = pairs
            deviceConfig.loadedSections.insert("customVars")
            checkLoadingComplete()

        case .stats(let subType, let payload):
            Self.logger.info("PARSED Stats subType=\(subType), \(payload.count) bytes")
            parseStats(subType: subType, payload: payload)
            deviceConfig.loadedSections.insert("stats")
            checkLoadingComplete()

        case .autoAddConfig(let bitmask, let maxHops):
            Self.logger.info("PARSED AutoAddConfig: bitmask=0x\(String(format: "%02x", bitmask)) maxHops=\(maxHops)")
            deviceConfig.autoAddBitmask = bitmask
            deviceConfig.autoAddMaxHops = maxHops

        case .contactsStart(let count):
            contactStore.handleContactsStart(count: count)

        case .contact(let contact):
            contactStore.handleContact(contact)

        case .endOfContacts(let lastmod):
            let shouldSyncChannels = contactStore.handleEndOfContacts(lastmod: lastmod)
            if shouldSyncChannels && !channelStore.hasCompletedInitialChannelSync {
                syncChannels()
                channelStore.hasCompletedInitialChannelSync = true
            }

        case .sent(let type, let expectedACK, let suggestedTimeout):
            Self.logger.info("PARSED Sent: type=\(type) expectedACK=\(expectedACK) timeout=\(suggestedTimeout)ms")
            DebugLogger.shared.log("Sent: type=\(type == 0 ? "direct" : "flood") ack=\(expectedACK) timeout=\(suggestedTimeout)ms", level: .rx)
            handleSentResponse(expectedACK: expectedACK, suggestedTimeoutMs: suggestedTimeout)

        case .contactMsgRecv(let message):
            Self.logger.info("Received direct message: \(message.text)")
            DebugLogger.shared.log("DM RX: '\(message.text.prefix(60))'", level: .rx)
            handleIncomingMessage(message)
            if messageStoreManager.isSyncingMessages {
                syncNextMessage()
            }

        case .channelMsgRecv(let message):
            Self.logger.info("CHANNEL RX: ch=\(message.channelIndex ?? 0) isOutgoing=\(message.isOutgoing) sender='\(message.senderName ?? "?")' text='\(message.text.prefix(40))'")
            DebugLogger.shared.log("CH RX: ch=\(message.channelIndex ?? 0) from='\(message.senderName ?? "?")' '\(message.text.prefix(40))'", level: .rx)
            handleIncomingMessage(message)
            if messageStoreManager.isSyncingMessages {
                syncNextMessage()
            }

        case .noMoreMessages:
            Self.logger.debug("No more messages")
            messageStoreManager.isSyncingMessages = false

        case .sendConfirmed(let ackCode, let roundTripMs):
            Self.logger.info("PARSED SendConfirmed: ackCode=\(ackCode) roundTrip=\(roundTripMs)ms")
            DebugLogger.shared.log("ACK confirmed: \(roundTripMs)ms", level: .rx)
            handleSendConfirmed(ackCode: ackCode, roundTripMs: roundTripMs)

        case .msgWaiting:
            Self.logger.info("PARSED MsgWaiting — syncing next message")
            syncNextMessage()

        case .loginSuccess(let permissionLevel):
            Self.logger.info("PUSH LoginSuccess: permissionLevel=\(permissionLevel)")
            handleLoginSuccess(permissionLevel: permissionLevel)

        case .loginFail:
            Self.logger.info("PUSH LoginFail")
            handleLoginFail()

        case .advert(let contact):
            Self.logger.debug("PUSH Advert from: \(contact.name)")
            handleAdvert(contact)
            // Also trigger debounced incremental sync for full data refresh
            requestDebouncedIncrementalSync()

        case .pathUpdated(let publicKey):
            Self.logger.debug("PUSH PathUpdated: key=\(publicKey.prefix(6).map { String(format: "%02x", $0) }.joined())")
            // Trigger debounced incremental contact sync to pick up the new path
            requestDebouncedIncrementalSync()

        case .newAdvert(let contact):
            contactStore.handleNewAdvert(contact, isInBackground: isInBackground)
            if isDiscovering {
                addAdvertAsDiscoveredNode(contact)
            }

        case .statusResponse(let info):
            Self.logger.info("PUSH StatusResponse: batt=\(info.batteryMV)mV uptime=\(info.uptime)")
            // Find which contact this status is for (most recent status request)
            remoteSessionManager.handleStatusResponse(info)

        case .traceData(let result):
            Self.logger.info("PUSH TraceData: tag=\(result.tag) hops=\(result.hops.count)")
            DebugLogger.shared.log("TRACE: \(result.hops.count) hops received", level: .rx)
            remoteSessionManager.handleTraceData(result)

        case .telemetryResponse(let senderKey, let readings):
            Self.logger.info("PUSH Telemetry: \(readings.count) readings from \(senderKey.prefix(6).map { String(format: "%02x", $0) }.joined())")
            remoteSessionManager.handleTelemetryResponse(senderKey: senderKey, readings: readings)

        case .controlData(let snr, let rssi, let pathLen, let payload):
            Self.logger.info("PUSH ControlData: snr=\(snr) rssi=\(rssi) pathLen=\(pathLen)")
            remoteSessionManager.handleControlData(snr: snr, rssi: rssi, pathLen: pathLen, payload: payload)

        case .channelInfo(let channel):
            let secretDesc = channel.secret.map { $0.map { String(format: "%02x", $0) }.joined() } ?? "none"
            Self.logger.info("Channel info: idx=\(channel.index) name='\(channel.name)' secret=\(secretDesc)")
            DebugLogger.shared.log("CH[\(channel.index)]: '\(channel.name)' secret=\(channel.secret != nil ? "\(channel.secret!.count)B" : "none")", level: .rx)
            channelStore.handleChannelInfo(channel)
            channelStore.checkChannelSyncComplete(maxChannels: deviceConfig.maxChannels)

        case .exportedContact(let url):
            Self.logger.info("EXPORT RESP: url='\(url.prefix(80))' (\(url.count) chars)")
            DebugLogger.shared.log("EXPORT: \(url.count) chars → \(url.prefix(60))...", level: .rx)
            if url.isEmpty {
                Self.logger.warning("EXPORT RESP: empty URL — device returned no card data")
            }

            #if !os(watchOS)
            if pendingMapUpload {
                // Map upload export — build data JSON and start device signing flow.
                pendingMapUpload = false
                if !url.isEmpty,
                   let dataJSON = MeshMapService.buildDataJSON(
                       exportURL: url,
                       freq: Double(deviceConfig.radioFrequency) / 1000.0,
                       bw:   Double(deviceConfig.radioBandwidth) / 1000.0,
                       sf:   Int(deviceConfig.radioSpreadingFactor),
                       cr:   Int(deviceConfig.radioCodingRate)
                   ) {
                    pendingMapDataJSON = dataJSON
                    DebugLogger.shared.log("MAP SIGN: starting device signing for \(dataJSON.count) byte payload", level: .info)
                    // Step 1: Initialize signing session
                    sendCommand(MeshCoreProtocol.buildSignStart(), label: "SIGN_START(map)")
                }
                return  // Don't trigger the user-facing "Link Copied" alert for map uploads
            }
            #endif

            // User-initiated export — show the "Link Copied" alert
            messageStoreManager.lastExportedURL = url

        case .advertPath(let info):
            Self.logger.info("AdvertPath: timestamp=\(info.recvTimestamp) pathLen=\(info.pathLen)")
            // Store for the contact that was queried
            remoteSessionManager.handleAdvertPathResponse(info)

        case .allowedRepeatFreq(let ranges):
            Self.logger.info("AllowedRepeatFreq: \(ranges.count) ranges")
            remoteSessionManager.handleAllowedRepeatFreq(ranges)

        case .currentAdvert(let adData):
            Self.logger.debug("Current advert: \(adData.count) bytes")

        case .rawData(let pktData):
            Self.logger.debug("Raw data: \(pktData.count) bytes")

        case .contactDeleted(let publicKey):
            let name = contacts.first(where: { $0.publicKeyPrefix == publicKey.prefix(6) })?.name ?? "Unknown"
            contactStore.handleContactDeleted(publicKey: publicKey)
            connectionManager.lastErrorMessage = "Contact \"\(name)\" was removed from device to make room for new contacts."

        case .contactsFull(let maxContacts):
            Self.logger.warning("Contact storage full: \(maxContacts)")
            connectionManager.lastErrorMessage = "Contact storage is full (\(maxContacts) contacts). New contacts cannot be added."
            postEventNotification(title: "Contact Storage Full", body: "Device has reached \(maxContacts) contacts. New contacts cannot be added.", threadId: "system")

        #if !os(watchOS)
        case .signStartResp(let maxLength):
            // Step 2: Sign session initialized — send SHA-256 hash of the data JSON
            guard let dataJSON = pendingMapDataJSON else {
                DebugLogger.shared.log("MAP SIGN: signStart received but no pending data", level: .warning)
                break
            }
            DebugLogger.shared.log("MAP SIGN: session ready, maxLen=\(maxLength)", level: .info)

            // SHA-256 hash of the JSON string
            guard let jsonBytes = dataJSON.data(using: .utf8) else { break }
            let hashBytes = Data(SHA256.hash(data: jsonBytes))
            DebugLogger.shared.log("MAP SIGN: sending \(hashBytes.count)-byte SHA-256 hash to device", level: .info)

            // Send hash as sign data (32 bytes fits in one BLE chunk)
            sendCommand(MeshCoreProtocol.buildSignData(chunk: hashBytes), label: "SIGN_DATA(map)")

            // Step 3: Request signature
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.sendCommand(MeshCoreProtocol.buildSignFinish(), label: "SIGN_FINISH(map)")
            }

        case .signatureResp(let signature):
            // Step 4: Got signature — upload to map
            guard let dataJSON = pendingMapDataJSON else {
                DebugLogger.shared.log("MAP SIGN: signature received but no pending data", level: .warning)
                break
            }
            let sigHex = signature.map { String(format: "%02x", $0) }.joined()
            let pubKeyHex = deviceConfig.publicKeyHex
            DebugLogger.shared.log("MAP SIGN: got \(signature.count)-byte signature, uploading", level: .info)

            pendingMapDataJSON = nil
            MeshMapService.shared.uploadSignedNode(
                dataJSON: dataJSON,
                signatureHex: sigHex,
                publicKeyHex: pubKeyHex
            )
        #endif

        case .unknown(let type, let payload):
            if type == 0x88 {
                let snr = payload.count > 0 ? Int8(bitPattern: payload[0]) : 0
                let rssi = payload.count > 1 ? Int8(bitPattern: payload[1]) : 0
                Self.logger.debug("LOG_RX_DATA (0x88): snr=\(Float(snr)/4.0) rssi=\(rssi) rawLen=\(payload.count - 2)")
                messageStoreManager.handleLogRxData(payload)
            } else if type >= 0x80 {
                Self.logger.debug("Ignoring push notification 0x\(String(format: "%02x", type)), \(payload.count) bytes payload")
            } else {
                Self.logger.warning("Unhandled response 0x\(String(format: "%02x", type)), \(payload.count) bytes payload")
            }
        }
    }

    /// Handle RESP_CODE_SENT — device accepted our message. Mark as .sent and track ACK.
    private func handleSentResponse(expectedACK: UInt32, suggestedTimeoutMs: UInt32) {
        remoteSessionManager.handleSentResponse(expectedACK: expectedACK, suggestedTimeoutMs: suggestedTimeoutMs)
        messageStoreManager.handleSentResponse(expectedACK: expectedACK, suggestedTimeoutMs: suggestedTimeoutMs)
    }

    private func handleSendConfirmed(ackCode: UInt32, roundTripMs: UInt32) {
        messageStoreManager.handleSendConfirmed(ackCode: ackCode, roundTripMs: roundTripMs)
    }

    // clearAllMessages, clearAllDrafts removed — views use MessageStoreManager directly

    private func handleAdvert(_ contact: Contact) {
        contactStore.handleAdvert(contact)
        if isDiscovering {
            addAdvertAsDiscoveredNode(contact)
        }
    }

    private func addAdvertAsDiscoveredNode(_ contact: Contact) {
        remoteSessionManager.addAdvertAsDiscoveredNode(contact)
    }

    private func handleLoginSuccess(permissionLevel: Int) {
        remoteSessionManager.handleLoginSuccess(permissionLevel: permissionLevel)
    }

    private func handleLoginFail() {
        remoteSessionManager.handleLoginFail()
    }

    private func handleErrorResponse(code: UInt8, description: String) {
        if remoteSessionManager.handleErrorResponse(code: code, description: description) { return }
        switch MeshCoreErrorCode(rawValue: code) {
        case .unsupportedCmd:
            // Show a friendly message — user may have triggered an unsupported feature
            connectionManager.lastErrorMessage = "This command is not supported on the current firmware version."
        case .illegalArg:
            // Protocol-level error (e.g. out-of-range index during init) — log only, not user-visible
            Self.logger.warning("ERR_CODE_ILLEGAL_ARG received — likely protocol/firmware mismatch, not user-actionable")
        case .notFound, .tableFull, .badState, .fileIOError:
            connectionManager.lastErrorMessage = description
        case nil:
            connectionManager.lastErrorMessage = description
        }
    }

    /// Handle an incoming message (direct or channel).
    private func handleIncomingMessage(_ message: Message) {
        // Route CLI responses to remote session manager first
        if remoteSessionManager.routeIncomingMessage(message) { return }

        // Delegate message storage, dedup, unread, haptics to store
        messageStoreManager.isInBackground = isInBackground
        if case .contact(let key) = navigationStore.sidebarSelection {
            messageStoreManager.selectedContactKey = key
        } else {
            messageStoreManager.selectedContactKey = nil
        }
        if let stored = messageStoreManager.handleIncomingMessage(message) {
            messageStoreManager.postLocalNotification(for: stored)
        }
    }

    private func checkLoadingComplete() {
        let required: Set<String> = ["selfInfo", "deviceInfo", "battAndStorage"]
        if required.isSubset(of: deviceConfig.loadedSections) {
            deviceConfig.isLoading = false
        }
    }

    private func parseStats(subType: UInt8, payload: Data) {
        var offset = 0

        switch subType {
        case 0:
            deviceConfig.statsBatteryMV = Int16(bitPattern: readUInt16(payload, offset: &offset))
            deviceConfig.statsUptime = readUInt32(payload, offset: &offset)
            deviceConfig.statsErrorFlags = readUInt16(payload, offset: &offset)
            deviceConfig.statsQueueLength = readUInt8(payload, offset: &offset)

        case 1:
            deviceConfig.statsNoiseFloor = Int16(bitPattern: readUInt16(payload, offset: &offset))
            deviceConfig.statsLastRSSI = Int8(bitPattern: readUInt8(payload, offset: &offset))
            deviceConfig.statsLastSNR = Int8(bitPattern: readUInt8(payload, offset: &offset))
            deviceConfig.statsTXAirtime = readUInt32(payload, offset: &offset)
            deviceConfig.statsRXAirtime = readUInt32(payload, offset: &offset)

        case 2:
            deviceConfig.statsPacketsReceived = readUInt32(payload, offset: &offset)
            deviceConfig.statsPacketsSent = readUInt32(payload, offset: &offset)
            deviceConfig.statsFloodCount = readUInt32(payload, offset: &offset)
            deviceConfig.statsDirectCount = readUInt32(payload, offset: &offset)
            deviceConfig.statsRecvFlood = readUInt32(payload, offset: &offset)
            deviceConfig.statsRecvDirect = readUInt32(payload, offset: &offset)

        default:
            Self.logger.debug("Unknown stats subtype \(subType)")
        }
    }

    // Network tools forwards removed — views use RemoteSessionManager directly

    // MARK: - Forwarding: Channel Sync → ChannelStore

    private func syncChannels() {
        channelStore.syncChannels(maxChannels: deviceConfig.maxChannels)
    }

    // setChannel removed — views use ChannelStore directly

    // MARK: - Binary Helpers

    private func readUInt8(_ data: Data, offset: inout Int) -> UInt8 {
        guard offset < data.count else { return 0 }
        let v = data[offset]; offset += 1; return v
    }

    private func readUInt16(_ data: Data, offset: inout Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        var v: UInt16 = 0
        _ = withUnsafeMutableBytes(of: &v) { dest in
            data.copyBytes(to: dest, from: offset..<offset+2)
        }
        offset += 2; return UInt16(littleEndian: v)
    }

    private func readUInt32(_ data: Data, offset: inout Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        var v: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &v) { dest in
            data.copyBytes(to: dest, from: offset..<offset+4)
        }
        offset += 4; return UInt32(littleEndian: v)
    }
}
