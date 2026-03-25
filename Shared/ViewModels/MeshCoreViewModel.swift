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

/// Radio config verification result.
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
/// On compact (iPhone), this drives the push navigation.
/// On regular width (iPad/Mac), this drives the detail pane.
enum SidebarSelection: Hashable {
    case publicChannel
    case channel(UInt8)
    case contact(Data) // publicKeyPrefix
    case settings
    case map
    #if os(macOS) || targetEnvironment(macCatalyst)
    case usbTerminal
    case usbDevice
    #endif
}

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

    // MARK: - Forwarded State (computed, delegates to stores)
    // These replace the old @Published properties. The bridge in observeStores()
    // fires objectWillChange when any store property changes.

    var contacts: [Contact] {
        get { contactStore.contacts }
        set { contactStore.contacts = newValue }
    }

    var pendingNewContacts: [Contact] {
        get { contactStore.pendingNewContacts }
        set { contactStore.pendingNewContacts = newValue }
    }

    var contactGroups: [ContactStore.ContactGroup] {
        get { contactStore.contactGroups }
        set { contactStore.contactGroups = newValue }
    }

    var channels: [MeshChannel] {
        get { channelStore.channels }
        set { channelStore.channels = newValue }
    }

    var isSyncingChannels: Bool {
        get { channelStore.isSyncingChannels }
        set { channelStore.isSyncingChannels = newValue }
    }

    var messagesByContact: [Data: [Message]] {
        get { messageStoreManager.messagesByContact }
        set { messageStoreManager.messagesByContact = newValue }
    }

    var unreadCounts: [Data: Int] {
        get { messageStoreManager.unreadCounts }
        set { messageStoreManager.unreadCounts = newValue }
    }

    var lastExportedURL: String? {
        get { messageStoreManager.lastExportedURL }
        set { messageStoreManager.lastExportedURL = newValue }
    }

    var pendingChannelImport: ChannelStore.PendingChannelImport? {
        get { channelStore.pendingChannelImport }
        set { channelStore.pendingChannelImport = newValue }
    }

    var showChannelImportOptions: Bool {
        get { channelStore.showChannelImportOptions }
        set { channelStore.showChannelImportOptions = newValue }
    }

    var pendingMultiChannelImport: ChannelStore.PendingMultiChannelImport? {
        get { channelStore.pendingMultiChannelImport }
        set { channelStore.pendingMultiChannelImport = newValue }
    }

    var showMultiChannelImportOptions: Bool {
        get { channelStore.showMultiChannelImportOptions }
        set { channelStore.showMultiChannelImportOptions = newValue }
    }

    @Published var sidebarSelection: SidebarSelection? = nil

    // MARK: - Internet Map (non-watchOS only)
    #if !os(watchOS)
    /// Nodes fetched from the MeshCore internet map (map.meshcore.dev).
    @Published var internetMapNodes: [InternetMapNode] = []
    /// Set to true before sending CMD_EXPORT_CONTACT (self) for map upload.
    private var pendingMapUpload = false
    #endif

    /// Convenience: the currently selected contact, derived from sidebarSelection.
    var selectedContact: Contact? {
        guard case .contact(let key) = sidebarSelection else { return nil }
        return contacts.first { $0.publicKeyPrefix == key }
    }

    /// Convenience: whether the public channel is selected.
    var showPublicChannel: Bool {
        if case .publicChannel = sidebarSelection { return true }
        return false
    }

    /// Convenience: the currently selected channel index (non-public).
    var selectedChannelIndex: UInt8? {
        if case .channel(let idx) = sidebarSelection { return idx }
        return nil
    }
    // Connection state — forwarded from ConnectionManager
    var isScanning: Bool {
        get { connectionManager.isScanning }
        set { connectionManager.isScanning = newValue }
    }
    var discoveredPeripherals: [DiscoveredPeripheral] {
        connectionManager.discoveredPeripherals
    }
    var connectionState: BLEConnectionState {
        get { connectionManager.connectionState }
        set { connectionManager.connectionState = newValue }
    }
    var connectedDeviceName: String? {
        get { connectionManager.connectedDeviceName }
        set { connectionManager.connectedDeviceName = newValue }
    }
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

    typealias ContactGroup = ContactStore.ContactGroup
    typealias ContactStatus = ContactStore.ContactStatus

    func setNickname(_ nickname: String, for contact: Contact) { contactStore.setNickname(nickname, for: contact) }
    func nickname(for contact: Contact) -> String? { contactStore.nickname(for: contact) }
    func displayName(for contact: Contact) -> String { contactStore.displayName(for: contact) }
    func channelSenderDisplayName(_ rawSenderName: String) -> String { contactStore.channelSenderDisplayName(rawSenderName) }
    func contactStatus(for contact: Contact) -> ContactStatus { contactStore.contactStatus(for: contact) }
    func contactStatusColor(for contact: Contact) -> Color { contactStore.contactStatusColor(for: contact) }

    // MARK: - Forwarding: Notes → ContactStore

    func loadContactNotesFromiCloud() { contactStore.loadContactNotesFromiCloud() }
    func setNote(_ note: String, for contact: Contact) { contactStore.setNote(note, for: contact) }
    func note(for contact: Contact) -> String { contactStore.note(for: contact) }
    func hasNote(for contact: Contact) -> Bool { contactStore.hasNote(for: contact) }

    // MARK: - Forwarding: Drafts → MessageStoreManager

    func saveDraft(_ text: String, for contactKey: Data) { messageStoreManager.saveDraft(text, for: contactKey) }
    func loadDraft(for contactKey: Data) -> String { messageStoreManager.loadDraft(for: contactKey) }
    func hasDraft(for contactKey: Data) -> Bool { messageStoreManager.hasDraft(for: contactKey) }

    // MARK: - Forwarding: Groups → ContactStore

    func loadContactGroupsFromiCloud() { contactStore.loadContactGroupsFromiCloud() }
    func addContactGroup(name: String, emoji: String) { contactStore.addContactGroup(name: name, emoji: emoji) }
    func deleteContactGroup(_ group: ContactGroup) { contactStore.deleteContactGroup(group) }
    func addContactToGroup(_ contact: Contact, group: ContactGroup) { contactStore.addContactToGroup(contact, group: group) }
    func removeContactFromGroup(_ contact: Contact, group: ContactGroup) { contactStore.removeContactFromGroup(contact, group: group) }
    func contactsInGroup(_ group: ContactGroup) -> [Contact] { contactStore.contactsInGroup(group) }

    // MARK: - Forwarding: Channel Notify → ChannelStore

    typealias ChannelNotifyMode = ChannelStore.ChannelNotifyMode

    func channelNotifyMode(for channelName: String) -> ChannelNotifyMode { channelStore.channelNotifyMode(for: channelName) }
    func setChannelNotifyMode(_ mode: ChannelNotifyMode, for channelName: String) { channelStore.setChannelNotifyMode(mode, for: channelName) }

    // MARK: - Battery Calibration (per-device, iCloud synced)

    @Published var batteryCalibration: BatteryCalibration?

    func loadBatteryCalibration() {
        let key = "battery.cal.\(deviceConfig.publicKeyHex)"
        guard let data = iCloudStore.data(forKey: key),
              let cal = try? JSONDecoder().decode(BatteryCalibration.self, from: data) else { return }
        batteryCalibration = cal
    }

    func saveBatteryCalibration(_ cal: BatteryCalibration) {
        let key = "battery.cal.\(deviceConfig.publicKeyHex)"
        if let data = try? JSONEncoder().encode(cal) {
            iCloudStore.set(data, forKey: key)
            iCloudStore.synchronize()
        }
    }

    func resetBatteryCalibration() {
        let key = "battery.cal.\(deviceConfig.publicKeyHex)"
        iCloudStore.removeObject(forKey: key)
        iCloudStore.synchronize()
        batteryCalibration = nil
    }

    func updateBatteryCalibration(rawMillivolts: UInt16, chemistry: BatteryChemistry) {
        let rawVoltage = Double(rawMillivolts) / 1000.0
        var cal = batteryCalibration ?? BatteryCalibration(chemistry: chemistry.rawValue)
        cal.chemistry = chemistry.rawValue
        cal.updateWithReading(rawVoltage, theoreticalMax: chemistry.theoreticalMax)
        batteryCalibration = cal
        saveBatteryCalibration(cal)
    }

    // MARK: - Forwarding: Spotlight → ContactStore

    #if canImport(CoreSpotlight)
    func indexContactsForSpotlight() { contactStore.indexContactsForSpotlight() }

    func navigateToContact(pubkeyHex: String) {
        if let contact = contacts.first(where: {
            $0.publicKey.map { String(format: "%02x", $0) }.joined() == pubkeyHex
        }) {
            sidebarSelection = .contact(contact.publicKeyPrefix)
        }
    }
    #endif

    // MARK: - Forwarding: Path Hash → ContactStore

    func contactNameForHash(_ hashHex: String) -> String? { contactStore.contactNameForHash(hashHex) }

    // Remote sessions — forwarded from RemoteSessionManager
    var remoteSessions: [Data: RemoteDeviceSession] {
        remoteSessionManager.remoteSessions
    }
    var hasActiveManagementSession: Bool {
        remoteSessionManager.hasActiveManagementSession
    }

    /// Last error message received from the device (shown as alert).
    @Published var lastErrorMessage: String?

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
        remoteSessionManager.showError = { [weak self] msg in self?.lastErrorMessage = msg }
        remoteSessionManager.onStateChanged = { [weak self] in self?.objectWillChange.send() }
        #if os(macOS) || targetEnvironment(macCatalyst)
        remoteSessionManager.sendUSBCLI = { [weak self] cmd in self?.connectionManager.sendUSBCLI(cmd) }
        #endif
    }

    /// Wire ConnectionManager callbacks for frame dispatch and lifecycle events.
    private func wireConnectionCallbacks() {
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

        // Connection loss notification
        if previousState == .connecting || previousState == .ready {
            if self.isInBackground && NotificationPreferences.shared.notifyConnection {
                let deviceName = self.connectedDeviceName ?? "radio"
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
    private func observeStores() {
        func trackChanges() {
            withObservationTracking {
                // Touch all store properties that views read via the ViewModel
                _ = self.contactStore.contacts
                _ = self.contactStore.pendingNewContacts
                _ = self.contactStore.contactGroups
                _ = self.channelStore.channels
                _ = self.channelStore.isSyncingChannels
                _ = self.channelStore.pendingChannelImport
                _ = self.channelStore.showChannelImportOptions
                _ = self.channelStore.pendingMultiChannelImport
                _ = self.channelStore.showMultiChannelImportOptions
                _ = self.messageStoreManager.messagesByContact
                _ = self.messageStoreManager.unreadCounts
                _ = self.messageStoreManager.lastExportedURL
                // ConnectionManager properties
                _ = self.connectionManager.isScanning
                _ = self.connectionManager.discoveredPeripherals
                _ = self.connectionManager.connectionState
                _ = self.connectionManager.connectedDeviceName
                _ = self.connectionManager.bleStatusMessage
                _ = self.connectionManager.scanRetryCount
                _ = self.connectionManager.requestShowScanner
                // DeviceConfig properties (@Observable)
                _ = self.deviceConfig.deviceName
                _ = self.deviceConfig.publicKeyHex
                _ = self.deviceConfig.batteryMillivolts
                _ = self.deviceConfig.isLoading
                _ = self.deviceConfig.radioFrequency
                _ = self.deviceConfig.radioTXPower
                _ = self.deviceConfig.blePIN
                _ = self.deviceConfig.autoAddBitmask
                _ = self.deviceConfig.customVars.count
                _ = self.deviceConfig.maxChannels
                // RemoteSessionManager properties
                _ = self.remoteSessionManager.discoveredNodes
                _ = self.remoteSessionManager.isDiscovering
                _ = self.remoteSessionManager.discoverFallbackMessage
                _ = self.remoteSessionManager.lastTraceResult
                _ = self.remoteSessionManager.pendingTraceTag
                _ = self.remoteSessionManager.detailContactForTrace
                _ = self.remoteSessionManager.pendingStatusKey
                _ = self.remoteSessionManager.pendingTelemetryKey
                _ = self.remoteSessionManager.pendingAdvertPathKey
                _ = self.remoteSessionManager.allowedRepeatFreqRanges
            } onChange: {
                DispatchQueue.main.async { [weak self] in
                    self?.objectWillChange.send()
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
        sendTextMessage(text, to: contact)
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

    func updateAppBadge() { messageStoreManager.updateAppBadge() }
    func playHapticFeedback() { messageStoreManager.playHapticFeedback() }
    func playReceiveHaptic() { messageStoreManager.playReceiveHaptic() }

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
                body: "Connected to \(connectedDeviceName ?? "radio")",
                threadId: "connection"
            )
        }
        channelStore.hasCompletedInitialChannelSync = false
        refreshAllSettings()
        requestContacts(fullSync: true)
        syncNextMessage()
    }

    /// Manually refresh contacts, channels, and settings from the device.
    func refreshAll() {
        guard connectionState == .ready else { return }
        refreshAllSettings()
        requestContacts(fullSync: true)
    }

    // MARK: - Scanning & Connection (forwarded to ConnectionManager)

    func requestAutoScan() { connectionManager.requestAutoScan() }
    func startScanning() { connectionManager.startScanning() }
    func stopScanning() { connectionManager.stopScanning() }
    func handleScanTimeout() { connectionManager.handleScanTimeout() }
    func connect(to peripheral: DiscoveredPeripheral) { connectionManager.connect(to: peripheral) }

    /// Whether the UI should present the scanner sheet — forwarded from ConnectionManager.
    var requestShowScanner: Bool {
        get { connectionManager.requestShowScanner }
        set { connectionManager.requestShowScanner = newValue }
    }

    func connectWiFi(host: String, port: UInt16 = 5000) { connectionManager.connectWiFi(host: host, port: port) }
    func disconnectWiFi() { connectionManager.disconnectWiFi() }

    #if os(macOS) || targetEnvironment(macCatalyst)
    func connectUSB(port: String) { connectionManager.connectUSB(port: port) }

    func disconnectUSB() {
        remoteSessionManager.reset()
        connectionManager.disconnectUSB()
    }

    func sendUSBCLI(_ command: String) {
        connectionManager.sendUSBCLI(command)
        remoteSessionManager.usbCLIOutput.append(USBTerminalLine(text: "> \(command)", isCommand: true))
    }

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

    func disconnect() { connectionManager.disconnect() }

    // MARK: - Protocol Commands

    // sendCommand routing moved to ConnectionManager.
    // ViewModel calls connectionManager.sendCommand directly.
    private func sendCommand(_ data: Data, label: String) {
        connectionManager.sendCommand(data, label: label)
    }

    func sendAppStart() {
        sendCommand(MeshCoreProtocol.buildAppStart(), label: "APP_START")
    }

    func requestDeviceInfo() {
        sendCommand(MeshCoreProtocol.buildDeviceQuery(), label: "DEVICE_QUERY")
    }

    /// Verify radio configuration by requesting all parameters and logging them to DebugLogger.
    /// Used to diagnose potential config corruption from malformed frames.
    @Published var isVerifyingConfig = false

    func verifyRadioConfig() {
        DebugLogger.shared.log("=== RADIO CONFIG VERIFICATION START ===", level: .info)
        isVerifyingConfig = true

        // Request device info (firmware, model)
        DebugLogger.shared.log("Requesting DEVICE_QUERY...", level: .tx)
        requestDeviceInfo()

        // Request self info (radio params, name, pubkey)
        DebugLogger.shared.log("Requesting APP_START for SELF_INFO...", level: .tx)
        sendAppStart()

        // Request tuning params
        DebugLogger.shared.log("Requesting GET_TUNING_PARAMS...", level: .tx)
        requestTuningParams()

        // Request battery/storage
        DebugLogger.shared.log("Requesting GET_BATT_AND_STORAGE...", level: .tx)
        requestBattAndStorage()

        // Request device time
        DebugLogger.shared.log("Requesting GET_DEVICE_TIME...", level: .tx)
        requestDeviceTime()

        // Collect results after responses arrive
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            DebugLogger.shared.log("=== RADIO CONFIG VERIFICATION COMPLETE ===", level: .info)
            self.isVerifyingConfig = false
            self.lastConfigVerification = buildConfigVerification()
        }
    }

    /// Last radio config verification result for display.
    @Published var lastConfigVerification: RadioConfigVerification?

    private func buildConfigVerification() -> RadioConfigVerification {
        let c = deviceConfig
        let freqMHz = Double(c.radioFrequency) / 1000.0
        let bwKHz = Double(c.radioBandwidth) / 1000.0
        let battV = String(format: "%.2fV", Double(c.batteryMillivolts) / 1000.0)
        let battPct = c.batteryPercent()
        let (regionCheck, regionMsg) = checkFrequencyForRegion(freqHz: c.radioFrequency)
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

    private func checkFrequencyForRegion(freqHz: UInt32) -> (RegionCheck, String) {
        let freqMHz = Double(freqHz) / 1000.0
        // Use device coordinates if available, otherwise check frequency bands directly
        let lat = deviceConfig.latitude
        let lon = deviceConfig.longitude
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

    private func requestDebouncedIncrementalSync() { contactStore.requestDebouncedIncrementalSync() }
    func requestContacts(fullSync: Bool = false) { contactStore.requestContacts(fullSync: fullSync) }

    func sendAdvertise(type: UInt8 = 0) {
        // Apply GPS fudge before advertising so the broadcast position is fudged
        #if !os(watchOS)
        let radius = UserDefaults.standard.double(forKey: "locationPrivacyRadius")
        if radius > 0 {
            let locManager = CLLocationManager()
            if let location = locManager.location {
                let (fLat, fLon) = fudgeLocation(lat: location.coordinate.latitude, lon: location.coordinate.longitude)
                sendCommand(MeshCoreProtocol.buildSetAdvertLatLon(latitude: fLat, longitude: fLon), label: "FUDGE_LATLON")
                DebugLogger.shared.log("ADVERT: fudged GPS applied before advert", level: .tx)
            }
        }
        #endif
        sendCommand(MeshCoreProtocol.buildSendSelfAdvert(advertType: type), label: "SELF_ADVERT")
    }

    // MARK: - Forwarding: Favourites/Contact Mgmt → ContactStore

    var sortedContacts: [Contact] { contactStore.sortedContacts }
    func toggleFavourite(for contact: Contact) { contactStore.toggleFavourite(for: contact) }
    func setContactPath(_ contact: Contact, pathLen: Int8, pathData: Data) { contactStore.setContactPath(contact, pathLen: pathLen, pathData: pathData) }
    func updateContactFlags(_ contact: Contact, newFlags: UInt8) { contactStore.updateContactFlags(contact, newFlags: newFlags) }

    func requestBattAndStorage() {
        sendCommand(MeshCoreProtocol.buildGetBattAndStorage(), label: "GET_BATT")
    }

    func requestDeviceTime() {
        sendCommand(MeshCoreProtocol.buildGetDeviceTime(), label: "GET_TIME")
    }

    func requestTuningParams() {
        sendCommand(MeshCoreProtocol.buildGetTuningParams(), label: "GET_TUNING")
    }

    func requestCustomVars() {
        sendCommand(MeshCoreProtocol.buildGetCustomVars(), label: "GET_CUSTOM_VARS")
    }

    func requestStats(subType: UInt8) {
        sendCommand(MeshCoreProtocol.buildGetStats(subType: subType), label: "GET_STATS(\(subType))")
    }

    func requestAutoAddConfig() {
        sendCommand(MeshCoreProtocol.buildGetAutoAddConfig(), label: "GET_AUTOADD")
    }

    func setAutoAddConfig(bitmask: UInt8) {
        sendCommand(MeshCoreProtocol.buildSetAutoAddConfig(bitmask: bitmask), label: "SET_AUTOADD(0x\(String(format: "%02x", bitmask)))")
        deviceConfig.autoAddBitmask = bitmask
    }

    func refreshAllSettings() {
        deviceConfig.isLoading = true
        deviceConfig.loadedSections = []
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

    // MARK: - Settings Commands

    func setAdvertName(_ name: String) {
        sendCommand(MeshCoreProtocol.buildSetAdvertName(name), label: "SET_ADVERT_NAME")
        deviceConfig.deviceName = name
    }

    /// Set local device's advertised location. Privacy fudge is applied here.
    /// This is the ONLY path that writes coordinates to our local radio.
    /// Remote management "set lat/lon" goes to other devices and is not fudged.
    func setAdvertLatLon(latitude: Double, longitude: Double) {
        let (fLat, fLon) = fudgeLocation(lat: latitude, lon: longitude)
        sendCommand(MeshCoreProtocol.buildSetAdvertLatLon(latitude: fLat, longitude: fLon), label: "SET_LATLON")
    }

    /// Session-stable random offset for location privacy. Regenerated on app launch
    /// or when the privacy radius setting changes.
    private static var locationFudgeAngle: Double = Double.random(in: 0..<(2 * .pi))
    private static var locationFudgeFraction: Double = Double.random(in: 0...1)

    /// Apply a privacy offset to coordinates. The offset is consistent within a session.
    func fudgeLocation(lat: Double, lon: Double) -> (Double, Double) {
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

    /// Stop periodic phone GPS syncing.
    func stopAutoLocationUpdates() {
        locationUpdateTimer?.invalidate()
        locationUpdateTimer = nil
        DebugLogger.shared.log("PHONE GPS: auto-update stopped", level: .info)
    }

    /// Send phone GPS location to radio (with fudge applied).
    private func setLocationFromPhoneGPS() {
        #if !os(watchOS)
        let locManager = CLLocationManager()
        guard let location = locManager.location else { return }
        let (fLat, fLon) = fudgeLocation(lat: location.coordinate.latitude, lon: location.coordinate.longitude)
        setAdvertLatLon(latitude: fLat, longitude: fLon)
        #endif
    }

    func setRadioParams(frequency: UInt32, bandwidth: UInt32, spreadingFactor: UInt8, codingRate: UInt8, repeatMode: Bool) {
        sendCommand(MeshCoreProtocol.buildSetRadioParams(
            frequency: frequency, bandwidth: bandwidth,
            spreadingFactor: spreadingFactor, codingRate: codingRate,
            repeatMode: repeatMode
        ), label: "SET_RADIO")
    }

    func setRadioTXPower(_ power: UInt8) {
        sendCommand(MeshCoreProtocol.buildSetRadioTXPower(power), label: "SET_TX_POWER")
    }

    func setTuningParams(rxDelayBase: UInt32, airtimeFactor: UInt32) {
        Self.logger.info("TUNING SET: rxDelay=\(rxDelayBase) airtime=\(airtimeFactor)")
        let frame = MeshCoreProtocol.buildSetTuningParams(rxDelayBase: rxDelayBase, airtimeFactor: airtimeFactor)
        Self.logger.info("TUNING TX: [\(frame.count) bytes] \(frame.map { String(format: "%02X", $0) }.joined(separator: " "))")
        sendCommand(frame, label: "SET_TUNING")
        deviceConfig.rxDelayBase = rxDelayBase
        deviceConfig.airtimeFactor = airtimeFactor
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.requestTuningParams()
        }
    }

    func setOtherParams(manualAddContacts: UInt8, telemetryBase: UInt8, telemetryLocation: UInt8, advertLocPolicy: UInt8, multiACK: UInt8) {
        DebugLogger.shared.log("SET_OTHER_PARAMS: manual=\(manualAddContacts) telBase=\(telemetryBase) telLoc=\(telemetryLocation) advLoc=\(advertLocPolicy) multiACK=\(multiACK)", level: .tx)
        // Optimistic update — reflect changes immediately so computed Bindings don't snap back
        deviceConfig.manualAddContacts = manualAddContacts
        deviceConfig.telemetryBase = telemetryBase
        deviceConfig.telemetryLocation = telemetryLocation
        deviceConfig.advertLocPolicy = advertLocPolicy
        deviceConfig.multiACK = multiACK
        sendCommand(MeshCoreProtocol.buildSetOtherParams(
            manualAddContacts: manualAddContacts, telemetryBase: telemetryBase,
            telemetryLocation: telemetryLocation, advertLocPolicy: advertLocPolicy,
            multiACK: multiACK
        ), label: "SET_OTHER_PARAMS")
    }

    func setDevicePIN(_ pin: UInt32) {
        sendCommand(MeshCoreProtocol.buildSetDevicePIN(pin), label: "SET_PIN")
    }

    func setDeviceTime(epochSeconds: UInt32) {
        sendCommand(MeshCoreProtocol.buildSetDeviceTime(epochSeconds: epochSeconds), label: "SET_TIME")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.requestDeviceTime()
        }
    }

    func setCustomVar(name: String, value: String) {
        sendCommand(MeshCoreProtocol.buildSetCustomVar(name: name, value: value), label: "SET_CUSTOM_VAR")
    }

    func rebootDevice() {
        sendCommand(MeshCoreProtocol.buildReboot(), label: "REBOOT")
    }

    func factoryReset() {
        sendCommand(MeshCoreProtocol.buildFactoryReset(), label: "FACTORY_RESET")
    }

    // MARK: - Forwarding: Contact Management → ContactStore

    func removeContact(_ contact: Contact) {
        contactStore.removeContact(contact)
        messagesByContact.removeValue(forKey: contact.publicKeyPrefix)
        unreadCounts.removeValue(forKey: contact.publicKeyPrefix)
        if case .contact(let key) = sidebarSelection, key == contact.publicKeyPrefix {
            sidebarSelection = nil
        }
    }

    func resetPath(for contact: Contact) { contactStore.resetPath(for: contact) }
    func shareContact(_ contact: Contact) { contactStore.shareContact(contact) }

    /// Export a contact as a meshcore:// URL. Result arrives as .exportedContact response.
    func exportContact(_ contact: Contact) {
        let keyHex = contact.publicKey.prefix(6).map { String(format: "%02x", $0) }.joined()
        Self.logger.info("EXPORT: requesting export for '\(contact.name)' key=\(keyHex) fullKeyLen=\(contact.publicKey.count)")
        lastExportedURL = nil
        let frame = MeshCoreProtocol.buildExportContact(publicKey: contact.publicKey)
        Self.logger.info("EXPORT: frame=[\(frame.count) bytes] \(frame.map { String(format: "%02x", $0) }.joined(separator: " "))")
        sendCommand(frame, label: "EXPORT_CONTACT")
    }

    /// Export self as a meshcore:// URL (send code byte only, no public key).
    func exportSelfContact() {
        Self.logger.info("EXPORT: requesting self contact export (frame=[1 byte] 11)")
        lastExportedURL = nil
        let frame = Data([0x11])  // CMD_EXPORT_CONTACT with no payload = export self
        sendCommand(frame, label: "EXPORT_SELF")
    }

    // MARK: - Internet Map

    #if !os(watchOS)
    /// Fetch internet map nodes from map.meshcore.dev and update `internetMapNodes`.
    /// Skips the network call if the cached data is less than 5 minutes old.
    func fetchInternetMapNodes() {
        Task {
            // fetchIfNeeded() is async — await ensures nodes are populated before
            // we copy them. The old 500ms sleep was a race condition that failed
            // whenever the API response took longer than half a second.
            await MeshMapService.shared.fetchIfNeeded()
            internetMapNodes = MeshMapService.shared.nodes
        }
    }

    /// Force-refresh internet map nodes regardless of cache age.
    func refreshInternetMapNodes() {
        Task {
            await MeshMapService.shared.fetch()
            internetMapNodes = MeshMapService.shared.nodes
        }
    }
    #endif

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

    // MARK: - Forwarding: Channel Import → ChannelStore

    typealias PendingChannelImport = ChannelStore.PendingChannelImport
    typealias PendingMultiChannelImport = ChannelStore.PendingMultiChannelImport

    func handleMeshCoreURL(_ urlString: String) {
        if channelStore.handleChannelURL(urlString) { return }
        if urlString.hasPrefix("meshcore://") {
            importContact(url: urlString)
        }
    }

    func importChannelAdd(_ data: PendingChannelImport) { channelStore.importChannelAdd(data, maxChannels: deviceConfig.maxChannels) }
    func importChannelReplaceAll(_ data: PendingChannelImport) { channelStore.importChannelReplaceAll(data) }
    func importMultiChannelsAdd(_ data: PendingMultiChannelImport) { channelStore.importMultiChannelsAdd(data, maxChannels: deviceConfig.maxChannels) }
    func importMultiChannelsReplace(_ data: PendingMultiChannelImport) { channelStore.importMultiChannelsReplace(data, maxChannels: deviceConfig.maxChannels) }

    // MARK: - Forwarding: Messaging → MessageStoreManager

    func messages(for contact: Contact) -> [Message] { messageStoreManager.messages(for: contact) }
    func unreadCount(for contact: Contact) -> Int { messageStoreManager.unreadCount(for: contact) }
    func markAsRead(_ contact: Contact) { messageStoreManager.markAsRead(contact) }
    func markAsRead(contactKey: Data) { messageStoreManager.markAsRead(contactKey: contactKey) }
    func firstUnreadIndex(in messages: [Message], for contactKey: Data) -> Int? { messageStoreManager.firstUnreadIndex(in: messages, for: contactKey) }
    func lastReadTimestamp(for contactKey: Data) -> Date? { messageStoreManager.lastReadTimestamp(for: contactKey) }
    func sendTextMessage(_ text: String, to contact: Contact) { messageStoreManager.sendTextMessage(text, to: contact) }
    func sendChannelMessage(_ text: String, channelIndex: UInt8 = 0) { messageStoreManager.sendChannelMessage(text, channelIndex: channelIndex) }

    func syncNextMessage() {
        #if os(macOS) || targetEnvironment(macCatalyst)
        guard !isUSBCLIConnected else { return }
        #endif
        messageStoreManager.syncNextMessage()
    }

    // MARK: - Remote Management

    // MARK: - Remote Management (forwarded to RemoteSessionManager)

    func remoteSession(for contact: Contact) -> RemoteDeviceSession { remoteSessionManager.remoteSession(for: contact) }
    func loginToRemoteDevice(_ contact: Contact, password: String, remember: Bool = true) { remoteSessionManager.loginToRemoteDevice(contact, password: password, remember: remember) }
    func sendCLICommand(_ command: String, to contact: Contact) { remoteSessionManager.sendCLICommand(command, to: contact) }
    func logoutFromRemoteDevice(_ contact: Contact) { remoteSessionManager.logoutFromRemoteDevice(contact) }
    func requestRemoteStatus(_ contact: Contact) { remoteSessionManager.requestRemoteStatus(contact) }
    func fetchRemoteSettings(for contact: Contact) { remoteSessionManager.fetchRemoteSettings(for: contact) }

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
            loadBatteryCalibration()
            mergeMessagesForCurrentRadio()
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
            if UserDefaults.standard.bool(forKey: "shareOnMeshMap"),
               info.latitude != 0 || info.longitude != 0 {
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
            updateBatteryCalibration(rawMillivolts: info.batteryMV, chemistry: chem)
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
            handleStatusResponse(info)

        case .traceData(let result):
            Self.logger.info("PUSH TraceData: tag=\(result.tag) hops=\(result.hops.count)")
            DebugLogger.shared.log("TRACE: \(result.hops.count) hops received", level: .rx)
            remoteSessionManager.handleTraceData(result)

        case .telemetryResponse(let senderKey, let readings):
            Self.logger.info("PUSH Telemetry: \(readings.count) readings from \(senderKey.prefix(6).map { String(format: "%02x", $0) }.joined())")
            remoteSessionManager.handleTelemetryResponse(senderKey: senderKey, readings: readings)

        case .controlData(let snr, let rssi, let pathLen, let payload):
            Self.logger.info("PUSH ControlData: snr=\(snr) rssi=\(rssi) pathLen=\(pathLen)")
            handleControlData(snr: snr, rssi: rssi, pathLen: pathLen, payload: payload)

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
            lastExportedURL = url
            #if !os(watchOS)
            if pendingMapUpload {
                pendingMapUpload = false
                if !url.isEmpty {
                    // Convert DeviceConfig radio units → Hz for the map API:
                    //   radioFrequency is stored in kHz → multiply by 1000 for Hz
                    //   radioBandwidth is stored in Hz  → use directly
                    MeshMapService.shared.uploadNode(
                        exportURL: url,
                        freq: Int(deviceConfig.radioFrequency) * 1000,
                        bw:   Int(deviceConfig.radioBandwidth),
                        sf:   Int(deviceConfig.radioSpreadingFactor),
                        cr:   Int(deviceConfig.radioCodingRate)
                    )
                }
            }
            #endif

        case .advertPath(let info):
            Self.logger.info("AdvertPath: timestamp=\(info.recvTimestamp) pathLen=\(info.pathLen)")
            // Store for the contact that was queried
            handleAdvertPathResponse(info)

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
            lastErrorMessage = "Contact \"\(name)\" was removed from device to make room for new contacts."

        case .contactsFull(let maxContacts):
            Self.logger.warning("Contact storage full: \(maxContacts)")
            lastErrorMessage = "Contact storage is full (\(maxContacts) contacts). New contacts cannot be added."
            postEventNotification(title: "Contact Storage Full", body: "Device has reached \(maxContacts) contacts. New contacts cannot be added.", threadId: "system")

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

    // handleACKTimeout, deleteMessage, clearAllMessages, clearAllDrafts, retryMessage -> MessageStoreManager

    func deleteMessage(_ message: Message, in contactKey: Data) { messageStoreManager.deleteMessage(message, in: contactKey) }
    func clearAllMessages() { messageStoreManager.clearAllMessages() }
    func clearAllDrafts() { messageStoreManager.clearAllDrafts() }
    func retryMessage(_ message: Message) { messageStoreManager.retryMessage(message) }

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
            lastErrorMessage = "This command is not supported on the current firmware version."
        case .illegalArg:
            // Protocol-level error (e.g. out-of-range index during init) — log only, not user-visible
            Self.logger.warning("ERR_CODE_ILLEGAL_ARG received — likely protocol/firmware mismatch, not user-actionable")
        case .notFound, .tableFull, .badState, .fileIOError:
            lastErrorMessage = description
        case nil:
            lastErrorMessage = description
        }
    }

    func sendRoomMessage(_ text: String, to contact: Contact) { messageStoreManager.sendRoomMessage(text, to: contact) }

    /// Handle an incoming message (direct or channel).
    private func handleIncomingMessage(_ message: Message) {
        // Route CLI responses to remote session manager first
        if remoteSessionManager.routeIncomingMessage(message) { return }

        // Delegate message storage, dedup, unread, haptics to store
        messageStoreManager.isInBackground = isInBackground
        messageStoreManager.selectedContactKey = selectedContact?.publicKeyPrefix
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

    // MARK: - Network Tools (forwarded to RemoteSessionManager)

    func startDiscover() { remoteSessionManager.startDiscover() }
    func stopDiscover() { remoteSessionManager.stopDiscover() }
    private func handleControlData(snr: Int8, rssi: Int8, pathLen: UInt8, payload: Data) { remoteSessionManager.handleControlData(snr: snr, rssi: rssi, pathLen: pathLen, payload: payload) }
    func traceRoute(to contact: Contact) { remoteSessionManager.traceRoute(to: contact) }
    func requestStatus(for contact: Contact) { remoteSessionManager.requestStatus(for: contact) }
    func requestTelemetry(for contact: Contact) { remoteSessionManager.requestTelemetry(for: contact) }
    private func handleStatusResponse(_ info: RemoteStatusInfo) { remoteSessionManager.handleStatusResponse(info) }
    func requestAdvertPath(for contact: Contact) { remoteSessionManager.requestAdvertPath(for: contact) }
    private func handleAdvertPathResponse(_ info: AdvertPathInfo) { remoteSessionManager.handleAdvertPathResponse(info) }
    func requestAllowedRepeatFreq() { remoteSessionManager.requestAllowedRepeatFreq() }

    // MARK: - Forwarding: Pending Contacts → ContactStore

    func acceptPendingContact(_ contact: Contact) { contactStore.acceptPendingContact(contact) }
    func rejectPendingContact(_ contact: Contact) { contactStore.rejectPendingContact(contact) }

    // MARK: - Forwarding: Channel Sync → ChannelStore

    private func syncChannels() {
        channelStore.syncChannels(maxChannels: deviceConfig.maxChannels)
    }

    func setChannel(index: UInt8, name: String, secret: Data? = nil) {
        channelStore.setChannel(index: index, name: name, secret: secret)
    }

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
