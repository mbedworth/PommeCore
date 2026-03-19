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

#if os(macOS)
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
    #if os(macOS)
    case usbTerminal
    #endif
}

@MainActor
final class MeshCoreViewModel: ObservableObject {
    private static let logger = Logger(subsystem: "com.meshcore", category: "ViewModel")

    @Published var contacts: [Contact] = []
    @Published var sidebarSelection: SidebarSelection? = nil

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
    @Published var isScanning = false
    @Published var discoveredPeripherals: [DiscoveredPeripheral] = []
    @Published var connectionState: BLEConnectionState = .disconnected
    @Published var connectedDeviceName: String?
    @Published var deviceConfig = DeviceConfig()

    /// All messages keyed by contact public key prefix (6 bytes).
    @Published var messagesByContact: [Data: [Message]] = [:]

    /// Unread message counts per contact key prefix.
    @Published var unreadCounts: [Data: Int] = [:]

    // MARK: - Contact Nicknames (iCloud sync via NSUbiquitousKeyValueStore)

    private let iCloudStore = NSUbiquitousKeyValueStore.default
    @Published private var nicknames: [String: String] = [:]

    private func loadNicknamesFromiCloud() {
        guard let data = iCloudStore.data(forKey: "contactNicknames"),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        // Truncate any nicknames that exceed 32 characters (sync safety)
        nicknames = decoded.mapValues { $0.count > 32 ? String($0.prefix(32)) : $0 }
    }

    private func saveNicknamesToiCloud() {
        if let data = try? JSONEncoder().encode(nicknames) {
            iCloudStore.set(data, forKey: "contactNicknames")
            iCloudStore.synchronize()
        }
    }

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
                self?.loadNicknamesFromiCloud()
                self?.loadContactNotesFromiCloud()
                self?.loadContactGroupsFromiCloud()
                self?.mergeMessagesForCurrentRadio()
            }
        }
    }

    func setNickname(_ nickname: String, for contact: Contact) {
        let key = contact.publicKey.map { String(format: "%02x", $0) }.joined()
        let trimmed = String(nickname.prefix(32))
        if trimmed.isEmpty {
            nicknames.removeValue(forKey: key)
        } else {
            nicknames[key] = trimmed
        }
        saveNicknamesToiCloud()
    }

    func nickname(for contact: Contact) -> String? {
        let key = contact.publicKey.map { String(format: "%02x", $0) }.joined()
        return nicknames[key]
    }

    func displayName(for contact: Contact) -> String {
        nickname(for: contact) ?? contact.name
    }

    /// Resolve a channel message sender name to a nickname if one exists.
    /// Matches the raw adv_name from the channel message against known contacts.
    func channelSenderDisplayName(_ rawSenderName: String) -> String {
        if let contact = contacts.first(where: { $0.name == rawSenderName }) {
            return displayName(for: contact)
        }
        return rawSenderName
    }

    // MARK: - Contact Notes (iCloud synced)

    @Published private var contactNotes: [String: String] = [:]

    func loadContactNotesFromiCloud() {
        guard let data = iCloudStore.data(forKey: "contactNotes"),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        contactNotes = decoded
    }

    private func saveContactNotesToiCloud() {
        if let data = try? JSONEncoder().encode(contactNotes) {
            iCloudStore.set(data, forKey: "contactNotes")
            iCloudStore.synchronize()
        }
    }

    func setNote(_ note: String, for contact: Contact) {
        let key = contact.publicKey.map { String(format: "%02x", $0) }.joined()
        if note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            contactNotes.removeValue(forKey: key)
        } else {
            contactNotes[key] = note
        }
        saveContactNotesToiCloud()
    }

    func note(for contact: Contact) -> String {
        let key = contact.publicKey.map { String(format: "%02x", $0) }.joined()
        return contactNotes[key] ?? ""
    }

    func hasNote(for contact: Contact) -> Bool {
        let key = contact.publicKey.map { String(format: "%02x", $0) }.joined()
        return contactNotes[key] != nil && !contactNotes[key]!.isEmpty
    }

    // MARK: - Message Drafts (iCloud synced)

    func saveDraft(_ text: String, for contactKey: Data) {
        let key = "draft.\(contactKey.map { String(format: "%02x", $0) }.joined())"
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            iCloudStore.removeObject(forKey: key)
        } else {
            iCloudStore.set(text, forKey: key)
        }
        iCloudStore.synchronize()
    }

    func loadDraft(for contactKey: Data) -> String {
        let key = "draft.\(contactKey.map { String(format: "%02x", $0) }.joined())"
        return iCloudStore.string(forKey: key) ?? ""
    }

    func hasDraft(for contactKey: Data) -> Bool {
        let key = "draft.\(contactKey.map { String(format: "%02x", $0) }.joined())"
        if let draft = iCloudStore.string(forKey: key), !draft.isEmpty {
            return true
        }
        return false
    }

    // MARK: - Contact Groups (iCloud synced)

    @Published var contactGroups: [ContactGroup] = []

    struct ContactGroup: Codable, Identifiable {
        let id: UUID
        var name: String
        var emoji: String
        var memberPubkeys: [String] // publicKey hex strings

        init(id: UUID = UUID(), name: String, emoji: String = "", memberPubkeys: [String] = []) {
            self.id = id
            self.name = name
            self.emoji = emoji
            self.memberPubkeys = memberPubkeys
        }
    }

    func loadContactGroupsFromiCloud() {
        guard let data = iCloudStore.data(forKey: "contactGroups"),
              let decoded = try? JSONDecoder().decode([ContactGroup].self, from: data) else { return }
        contactGroups = decoded
    }

    private func saveContactGroupsToiCloud() {
        if let data = try? JSONEncoder().encode(contactGroups) {
            iCloudStore.set(data, forKey: "contactGroups")
            iCloudStore.synchronize()
        }
    }

    func addContactGroup(name: String, emoji: String) {
        contactGroups.append(ContactGroup(name: name, emoji: emoji))
        saveContactGroupsToiCloud()
    }

    func deleteContactGroup(_ group: ContactGroup) {
        contactGroups.removeAll { $0.id == group.id }
        saveContactGroupsToiCloud()
    }

    func addContactToGroup(_ contact: Contact, group: ContactGroup) {
        let pubkeyHex = contact.publicKey.map { String(format: "%02x", $0) }.joined()
        if let idx = contactGroups.firstIndex(where: { $0.id == group.id }) {
            if !contactGroups[idx].memberPubkeys.contains(pubkeyHex) {
                contactGroups[idx].memberPubkeys.append(pubkeyHex)
                saveContactGroupsToiCloud()
            }
        }
    }

    func removeContactFromGroup(_ contact: Contact, group: ContactGroup) {
        let pubkeyHex = contact.publicKey.map { String(format: "%02x", $0) }.joined()
        if let idx = contactGroups.firstIndex(where: { $0.id == group.id }) {
            contactGroups[idx].memberPubkeys.removeAll { $0 == pubkeyHex }
            saveContactGroupsToiCloud()
        }
    }

    func contactsInGroup(_ group: ContactGroup) -> [Contact] {
        contacts.filter { contact in
            let hex = contact.publicKey.map { String(format: "%02x", $0) }.joined()
            return group.memberPubkeys.contains(hex)
        }
    }

    // MARK: - Channel Notification Modes (iCloud synced)

    enum ChannelNotifyMode: String {
        case all = "all"
        case mentionsOnly = "mentions"
        case muted = "muted"
    }

    func channelNotifyMode(for channelName: String) -> ChannelNotifyMode {
        let key = "channel.notify.\(channelName)"
        let raw = iCloudStore.string(forKey: key) ?? "all"
        return ChannelNotifyMode(rawValue: raw) ?? .all
    }

    func setChannelNotifyMode(_ mode: ChannelNotifyMode, for channelName: String) {
        let key = "channel.notify.\(channelName)"
        iCloudStore.set(mode.rawValue, forKey: key)
        iCloudStore.synchronize()
    }

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

    // MARK: - Spotlight Indexing

    #if canImport(CoreSpotlight)
    func indexContactsForSpotlight() {
        var items: [CSSearchableItem] = []
        for contact in contacts {
            let attrs = CSSearchableItemAttributeSet(contentType: .contact)
            attrs.displayName = displayName(for: contact)
            attrs.contentDescription = "MeshCore \(contact.type == .repeater ? "repeater" : contact.type == .room ? "room server" : "contact")"
            let pubkeyHex = contact.publicKey.map { String(format: "%02x", $0) }.joined()
            let item = CSSearchableItem(
                uniqueIdentifier: "meshcore.contact.\(pubkeyHex)",
                domainIdentifier: "com.mbedworth.meshcore.contacts",
                attributeSet: attrs
            )
            item.expirationDate = .distantFuture
            items.append(item)
        }
        CSSearchableIndex.default().indexSearchableItems(items)
    }

    func navigateToContact(pubkeyHex: String) {
        if let contact = contacts.first(where: {
            $0.publicKey.map { String(format: "%02x", $0) }.joined() == pubkeyHex
        }) {
            sidebarSelection = .contact(contact.publicKeyPrefix)
        }
    }
    #endif

    // MARK: - Path Hash Resolution

    /// Resolve a path hop hash to a known contact/repeater name.
    func contactNameForHash(_ hashHex: String) -> String? {
        let hashBytes = Data(stride(from: 0, to: hashHex.count, by: 2).compactMap { i in
            let start = hashHex.index(hashHex.startIndex, offsetBy: i)
            let end = hashHex.index(start, offsetBy: min(2, hashHex.distance(from: start, to: hashHex.endIndex)))
            return UInt8(hashHex[start..<end], radix: 16)
        })
        guard !hashBytes.isEmpty else { return nil }
        for contact in contacts where contact.type == .repeater {
            if contact.publicKeyPrefix.prefix(hashBytes.count) == hashBytes {
                return displayName(for: contact)
            }
        }
        return nil
    }

    /// Active remote management sessions keyed by contact public key prefix.
    /// Not @Published — sessions are ObservableObjects whose changes are
    /// forwarded to the ViewModel via objectWillChange so the contact list updates.
    private(set) var remoteSessions: [Data: RemoteDeviceSession] = [:]

    /// Cancellables for forwarding session objectWillChange to ViewModel.
    private var sessionCancellables: [Data: AnyCancellable] = [:]

    /// Whether any remote management session is currently logged in.
    var hasActiveManagementSession: Bool {
        remoteSessions.values.contains { session in
            if case .loggedIn = session.loginState { return true }
            return false
        }
    }

    /// Last error message received from the device (shown as alert).
    @Published var lastErrorMessage: String?

    /// BLE status message for error states (Bluetooth off, permission denied, etc.)
    @Published var bleStatusMessage: String?

    let bleManager = BLEManager()
    let wifiManager = WiFiConnectionManager()
    #if os(macOS)
    let usbManager = USBSerialManager()
    @Published var usbCLIOutput: [USBTerminalLine] = []
    #endif
    private var cancellables = Set<AnyCancellable>()
    private let messageStore = MessageStore()

    /// Maps expected ACK code → message ID for delivery tracking.
    private var pendingACKs: [UInt32: (contactKeyHash: Data, messageID: UUID)] = [:]

    /// Tracks the most recent outgoing channel message for 0x88-based echo detection.
    /// When LOG_RX_DATA (0x88) arrives within 30s of a channel send, a repeater forwarded it.
    private var pendingChannelEcho: (id: UUID, channelKey: Data, sent: Date)?

    /// Whether we're currently syncing queued messages.
    private var isSyncingMessages = false

    /// Whether an auto-scan has been requested (waiting for BLE poweredOn).
    private var pendingAutoScan = false

    /// Number of auto-scan retry attempts remaining.
    @Published var scanRetryCount: Int = 0
    private let maxScanRetries = 3
    private var scanRetryTask: Task<Void, Never>?

    /// Whether the app is currently in the background (for local notifications).
    var isInBackground = false

    /// Login timeout task — cancelled when login succeeds or fails.
    private var loginTimeoutTask: Task<Void, Never>?

    /// Debounce task for incremental contact sync (coalesces rapid advert/path pushes).
    private var contactSyncDebounceTask: Task<Void, Never>?

    /// Pending login credentials (stored between login request and success/failure response).
    private var pendingLoginPassword: String?
    private var pendingLoginRememberPassword: Bool = false

    /// Timeout tasks for network tool requests — cancelled when response arrives.
    private var traceTimeoutTask: Task<Void, Never>?
    private var statusTimeoutTask: Task<Void, Never>?
    private var telemetryTimeoutTask: Task<Void, Never>?
    private var pathTimeoutTask: Task<Void, Never>?
    private var discoverTimeoutTask: Task<Void, Never>?

    /// Last contacts sync lastmod — for incremental sync.
    private var lastContactsSync: UInt32 = 0

    /// Expected contact count from CONTACTS_START (for logging).
    private var expectedContactCount: UInt32 = 0

    /// Accumulates contacts during a sync before replacing the list.
    private var incomingContacts: [Contact] = []

    /// Whether a contact sync is currently in progress (prevents clobbering displayed contacts).
    private var isSyncingContacts = false

    /// Whether the current contact sync is incremental (merge) or full (replace).
    private var isIncrementalContactSync = false

    /// Channels reported by the device.
    @Published var channels: [MeshChannel] = []

    /// Incoming channels buffer during sync.
    private var incomingChannels: [MeshChannel] = []

    /// Whether channel sync is in progress.
    @Published var isSyncingChannels = false
    private var hasCompletedInitialChannelSync = false

    /// Pending contacts discovered via PUSH_CODE_NEW_ADVERT (manual_add_contacts mode).
    @Published var pendingNewContacts: [Contact] = []

    /// Discovered nodes from the discover feature.
    @Published var discoveredNodes: [DiscoveredNode] = []

    /// Whether a discover scan is in progress.
    @Published var isDiscovering = false

    /// Whether CMD_SEND_CONTROL_DATA is unsupported on this firmware (remembered per session).
    private var discoverUnsupported = false

    /// Informational message shown in the Discover view (e.g. fallback notice).
    @Published var discoverFallbackMessage: String?

    /// Most recent trace route result.
    @Published var lastTraceResult: TraceResult?

    /// Most recent telemetry readings keyed by contact key prefix.
    @Published var telemetryByContact: [Data: [TelemetryReading]] = [:]

    /// Most recent status info keyed by contact key prefix.
    @Published var statusByContact: [Data: RemoteStatusInfo] = [:]

    /// Advert path info keyed by contact key prefix.
    @Published var advertPathByContact: [Data: AdvertPathInfo] = [:]

    /// Allowed repeat frequency ranges.
    @Published var allowedRepeatFreqRanges: [FrequencyRange] = []

    /// Active trace route tag for correlating responses.
    @Published private(set) var pendingTraceTag: UInt32?
    private var pendingTraceContact: Contact?
    @Published var detailContactForTrace: Contact?

    /// Contact key for which we're awaiting an advert path response.
    @Published private(set) var pendingAdvertPathKey: Data?

    /// Contact key for which we're awaiting a status response.
    @Published private(set) var pendingStatusKey: Data?

    /// Contact key for which we're awaiting a telemetry response.
    @Published private(set) var pendingTelemetryKey: Data?

    init() {
        setupSubscriptions()
        forwardDeviceConfigChanges()
        loadPersistedMessages()
        requestNotificationPermissions()
        Task { @MainActor in
            self.loadNicknamesFromiCloud()
            self.loadContactNotesFromiCloud()
            self.loadContactGroupsFromiCloud()
        }
        observeiCloudChanges()
        registerTerminationHandler()
    }

    private func forwardDeviceConfigChanges() {
        deviceConfig.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    private func loadPersistedMessages() {
        messagesByContact = messageStore.loadAllMessages()
        // Merge any messages synced from other devices via iCloud
        mergeMessagesFromiCloud()
    }

    private func persistMessages(for contactKeyHash: Data) {
        if let messages = messagesByContact[contactKeyHash] {
            messageStore.saveMessages(messages, for: contactKeyHash)
            syncMessagesToiCloud(for: contactKeyHash)
        }
    }

    // MARK: - iCloud Message Sync

    /// Sync the last 50 messages per contact to iCloud, keyed by radio pubkey.
    private func syncMessagesToiCloud(for contactKeyHash: Data) {
        guard UserDefaults.standard.object(forKey: "iCloudSyncEnabled") == nil
                || UserDefaults.standard.bool(forKey: "iCloudSyncEnabled") else { return }
        let radioKey = deviceConfig.publicKeyHex
        guard !radioKey.isEmpty else { return }

        let contactHex = contactKeyHash.map { String(format: "%02x", $0) }.joined()
        let key = "msg.\(radioKey.prefix(12)).\(contactHex)"

        guard let messages = messagesByContact[contactKeyHash] else { return }
        let recent = Array(messages.suffix(50))

        if let data = try? JSONEncoder().encode(recent), data.count < 60_000 {
            iCloudStore.set(data, forKey: key)
            // Don't call synchronize on every message — let the system batch
        }
    }

    /// On launch, merge iCloud messages with local messages.
    private func mergeMessagesFromiCloud() {
        guard UserDefaults.standard.object(forKey: "iCloudSyncEnabled") == nil
                || UserDefaults.standard.bool(forKey: "iCloudSyncEnabled") else { return }

        // We don't know the radio key yet at launch — defer to after SELF_INFO
    }

    /// Called after SELF_INFO when we know the radio's public key.
    func mergeMessagesForCurrentRadio() {
        let radioKey = deviceConfig.publicKeyHex
        guard !radioKey.isEmpty else { return }
        let prefix = "msg.\(radioKey.prefix(12))."

        let allKeys = iCloudStore.dictionaryRepresentation.keys
        var mergedCount = 0

        for key in allKeys where key.hasPrefix(prefix) {
            let contactHex = String(key.dropFirst(prefix.count))
            guard let contactKeyHash = Data(hexString: contactHex),
                  let data = iCloudStore.data(forKey: key),
                  let cloudMessages = try? JSONDecoder().decode([Message].self, from: data)
            else { continue }

            let localMessages = messagesByContact[contactKeyHash] ?? []
            let localIDs = Set(localMessages.map(\.id))
            var merged = localMessages

            for msg in cloudMessages where !localIDs.contains(msg.id) {
                merged.append(msg)
                mergedCount += 1
            }

            if merged.count > localMessages.count {
                merged.sort { $0.timestamp < $1.timestamp }
                messagesByContact[contactKeyHash] = merged
                messageStore.saveMessages(merged, for: contactKeyHash)
            }
        }

        if mergedCount > 0 {
            Self.logger.info("iCloud sync: merged \(mergedCount) messages from other devices")
        }
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

    /// Post a local notification for an incoming message when the app is backgrounded.
    /// Checks user notification preferences before sending.
    private func postLocalNotification(for message: Message) {
        guard isInBackground else { return }

        // Check notification preferences (synced via iCloud)
        let prefs = NotificationPreferences.shared
        let isChannel = message.channelIndex != nil
        let isRoom = contacts.first(where: { $0.publicKeyPrefix == message.contactKeyHash })?.type == .room

        if isChannel {
            guard prefs.notifyChannel else { return }
            // Check per-channel notify mode (mentions only)
            if let chIdx = message.channelIndex,
               let channel = channels.first(where: { $0.index == chIdx }) {
                let mode = channelNotifyMode(for: channel.name)
                if mode == .muted { return }
                if mode == .mentionsOnly {
                    let myName = deviceConfig.deviceName.lowercased()
                    guard !myName.isEmpty, message.text.lowercased().contains("@\(myName)") else { return }
                }
            }
        } else if isRoom {
            guard prefs.notifyRoom else { return }
        } else {
            guard prefs.notifyDirect else { return }
        }

        let content = UNMutableNotificationContent()
        content.sound = .default

        // Find contact name for the notification title (use nickname if set)
        let contact = contacts.first(where: { $0.publicKeyPrefix == message.contactKeyHash })
        let senderName = message.senderName
            ?? contact.map { displayName(for: $0) }

        if let channelIdx = message.channelIndex {
            let channelName = channels.first(where: { $0.index == channelIdx })?.name ?? "Channel"
            content.title = channelName
            if let name = message.senderName, !name.isEmpty {
                content.subtitle = name
            }
            // Group by channel
            content.threadIdentifier = "channel.\(channelIdx)"
        } else if let name = senderName {
            content.title = name
            // Group by contact
            content.threadIdentifier = "dm.\(message.contactKeyHash.map { String(format: "%02x", $0) }.joined())"
        } else {
            content.title = "New Message"
        }
        content.body = message.text

        // Include contact pubkey for quick reply and navigation
        if let contact {
            content.userInfo["contactPubkey"] = contact.publicKey.map { String(format: "%02x", $0) }.joined()
            content.userInfo["isChannel"] = isChannel
            if let chIdx = message.channelIndex {
                content.userInfo["channelIndex"] = chIdx
            }
            #if os(iOS)
            if !isChannel {
                content.categoryIdentifier = "MESSAGE_CATEGORY"
            }
            #endif
        }

        // Include badge count
        let totalUnread = unreadCounts.values.reduce(0, +)
        content.badge = NSNumber(value: totalUnread)

        DebugLogger.shared.log("NOTIF: posting notification for '\(message.text.prefix(30))'", level: .info)
        let request = UNNotificationRequest(
            identifier: message.id.uuidString,
            content: content,
            trigger: nil
        )
        let log = Self.logger
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                log.warning("Failed to post notification: \(error.localizedDescription)")
            }
        }
    }

    /// Post a notification for a system event (not a message).
    private func postEventNotification(title: String, body: String, threadId: String = "system") {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = threadId
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Update the app icon badge to reflect total unread messages.
    func updateAppBadge() {
        let totalUnread = unreadCounts.values.reduce(0, +)
        #if os(iOS)
        Task { @MainActor in
            try? await UNUserNotificationCenter.current().setBadgeCount(totalUnread)
        }
        #elseif os(macOS)
        NSApplication.shared.dockTile.badgeLabel = totalUnread > 0 ? "\(totalUnread)" : nil
        #endif
    }

    /// Trigger haptic feedback on message send.
    func playHapticFeedback() {
        #if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        #elseif os(watchOS)
        WKInterfaceDevice.current().play(.click)
        #endif
    }

    /// Trigger notification haptic on message receive.
    func playReceiveHaptic() {
        #if os(iOS)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        #elseif os(watchOS)
        WKInterfaceDevice.current().play(.notification)
        #endif
    }

    private func setupSubscriptions() {
        bleManager.receivedDataSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data in
                self?.handleReceivedData(data)
            }
            .store(in: &cancellables)

        // Background fast-path: parse PUSH_CODE_MSG_WAITING immediately on BLE queue
        // to trigger CMD_SYNC_NEXT_MESSAGE without waiting for main thread dispatch
        bleManager.receivedDataSubject
            .sink { [weak self] data in
                guard let self, data.count >= 1 else { return }
                let code = data[0]
                // PUSH_CODE_MSG_WAITING (0x83) — immediately request the message
                if code == 0x83 {
                    Self.logger.info("BG FAST-PATH: PUSH_CODE_MSG_WAITING — sending SYNC_NEXT_MESSAGE immediately")
                    DebugLogger.shared.log("NOTIF: 0x83 received, sending SYNC_NEXT immediately", level: .rx)
                    self.bleManager.send(data: Data([0x0A])) // CMD_SYNC_NEXT_MESSAGE
                }
            }
            .store(in: &cancellables)

        bleManager.$discoveredPeripherals
            .receive(on: DispatchQueue.main)
            .assign(to: &$discoveredPeripherals)

        bleManager.$connectedDeviceName
            .receive(on: DispatchQueue.main)
            .assign(to: &$connectedDeviceName)

        bleManager.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                let previousState = self.connectionState
                self.connectionState = state
                if state == .disconnected {
                    // Reset all login sessions on disconnect
                    for (_, session) in self.remoteSessions {
                        switch session.loginState {
                        case .loggingIn:
                            session.loginState = .loginFailed(message: "Device disconnected during login.")
                        case .loggedIn:
                            session.loginState = .notLoggedIn
                        default:
                            break
                        }
                    }
                    self.loginTimeoutTask?.cancel()
                    self.loginTimeoutTask = nil
                    self.traceTimeoutTask?.cancel()
                    self.statusTimeoutTask?.cancel()
                    self.telemetryTimeoutTask?.cancel()
                    self.pathTimeoutTask?.cancel()
                    self.discoverTimeoutTask?.cancel()
                    self.contactSyncDebounceTask?.cancel()
                    self.hasCompletedInitialChannelSync = false
                    self.stopAutoLocationUpdates()
                    self.deviceConfig = DeviceConfig()
                    self.forwardDeviceConfigChanges()
                    self.isSyncingMessages = false
                    self.isSyncingContacts = false
                    self.isIncrementalContactSync = false
                    self.lastContactsSync = 0
                    self.incomingContacts = []
                    self.channels = []
                    self.incomingChannels = []
                    self.isSyncingChannels = false
                    self.pendingNewContacts = []
                    self.discoveredNodes = []
                    self.isDiscovering = false
                    self.discoverUnsupported = false
                    self.discoverFallbackMessage = nil
                    self.lastTraceResult = nil
                    self.pendingTraceTag = nil
                    self.pendingStatusKey = nil
                    self.pendingAdvertPathKey = nil
                    self.pendingTelemetryKey = nil
                    self.allowedRepeatFreqRanges = []
                    // Mark pending outgoing messages as failed
                    for (contactKey, messages) in self.messagesByContact {
                        var updated = messages
                        var changed = false
                        for i in updated.indices where updated[i].isOutgoing && updated[i].status == .sending {
                            updated[i].status = .failed
                            changed = true
                        }
                        if changed {
                            self.messagesByContact[contactKey] = updated
                            self.persistMessages(for: contactKey)
                        }
                    }
                    self.pendingACKs.removeAll()

                    // If transitioning from connecting (reconnect attempts) to disconnected,
                    // show scanner after BLE layer starts auto-scanning
                    if previousState == .connecting || previousState == .ready {
                        if self.isInBackground && NotificationPreferences.shared.notifyConnection {
                            let deviceName = self.connectedDeviceName ?? "radio"
                            self.postEventNotification(
                                title: "Connection Lost",
                                body: "Lost connection to \(deviceName). Attempting to reconnect...",
                                threadId: "connection"
                            )
                        }
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
                    if self.isInBackground && previousState == .disconnected && NotificationPreferences.shared.notifyConnection {
                        self.postEventNotification(
                            title: "Reconnected",
                            body: "Connected to \(self.connectedDeviceName ?? "radio")",
                            threadId: "connection"
                        )
                    }
                    self.onDeviceReady()
                }
            }
            .store(in: &cancellables)

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

        bleManager.$bleStatusMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.bleStatusMessage = message
            }
            .store(in: &cancellables)

        // WiFi/TCP subscriptions
        wifiManager.receivedDataSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data in
                self?.handleReceivedData(data)
            }
            .store(in: &cancellables)

        wifiManager.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                guard let self else { return }
                if connected {
                    Self.logger.info("WiFi connected — initializing device")
                    self.connectionState = .ready
                    self.connectedDeviceName = "WiFi: \(self.wifiManager.connectedHost ?? "unknown")"
                    self.onDeviceReady()
                } else if self.wifiManager.connectedHost != nil {
                    // WiFi disconnected
                    if self.connectionState == .ready {
                        self.connectionState = .disconnected
                        self.connectedDeviceName = nil
                    }
                }
            }
            .store(in: &cancellables)

        // USB Serial subscriptions (macOS only)
        #if os(macOS)
        usbManager.receivedDataSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data in
                self?.handleReceivedData(data)
            }
            .store(in: &cancellables)

        usbManager.receivedLineSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] line in
                self?.usbCLIOutput.append(USBTerminalLine(text: line, isCommand: false))
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
                    self.onDeviceReady()
                }
            }
            .store(in: &cancellables)
        #endif
    }

    private func onDeviceReady() {
        refreshAllSettings()
        requestContacts(fullSync: true)
        isSyncingChannels = true
        incomingChannels = []
        syncNextMessage()
    }

    /// Manually refresh contacts, channels, and settings from the device.
    func refreshAll() {
        guard connectionState == .ready else { return }
        refreshAllSettings()
        requestContacts(fullSync: true)
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

    /// Whether the UI should present the scanner sheet (set by auto-scan after disconnect).
    @Published var requestShowScanner = false

    func connectWiFi(host: String, port: UInt16 = 5000) {
        wifiManager.connect(host: host, port: port)
    }

    func disconnectWiFi() {
        wifiManager.disconnect()
    }

    #if os(macOS)
    func connectUSB(port: String) {
        usbManager.connect(to: port)
    }

    func disconnectUSB() {
        usbManager.disconnect()
        if connectionState != .disconnected {
            connectionState = .disconnected
            connectedDeviceName = nil
        }
    }

    func sendUSBCLI(_ command: String) {
        usbManager.sendCLI(command)
        usbCLIOutput.append(USBTerminalLine(text: "> \(command)", isCommand: true))
    }
    #endif

    func disconnect() {
        bleManager.disconnect()
        // Auto-scan after user-initiated disconnect
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard connectionState == .disconnected else { return }
            requestShowScanner = true
            startScanning()
        }
    }

    // MARK: - Protocol Commands

    /// Routine commands that don't need hex dumps in the in-app debug log.
    private static let routineLabels: Set<String> = [
        "GET_BATT", "GET_TIME", "GET_TUNING", "GET_CUSTOM_VARS", "GET_STATS(0)",
        "GET_STATS(1)", "GET_STATS(2)", "GET_AUTOADD", "APP_START", "DEVICE_QUERY",
    ]

    private func sendCommand(_ data: Data, label: String) {
        let verbose = !Self.routineLabels.contains(label)

        if wifiManager.isConnected {
            let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
            Self.logger.info("TX(WiFi) \(label) [\(data.count) bytes]: \(hex)")
            if verbose { DebugLogger.shared.log("TX(WiFi) \(label) [\(data.count)B] \(hex)", level: .tx) }
            wifiManager.sendFrame(data)
            return
        }
        #if os(macOS)
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

        // End marker after a delay to allow responses
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            DebugLogger.shared.log("=== RADIO CONFIG VERIFICATION COMPLETE ===", level: .info)
            self.isVerifyingConfig = false
        }
    }

    /// Request an incremental contact sync with debouncing.
    /// Coalesces rapid-fire advert/path pushes into a single CMD_GET_CONTACTS.
    private func requestDebouncedIncrementalSync() {
        contactSyncDebounceTask?.cancel()
        contactSyncDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second debounce
            guard !Task.isCancelled, let self else { return }
            self.requestContacts()
        }
    }

    func requestContacts(fullSync: Bool = false) {
        let since: UInt32 = fullSync ? 0 : lastContactsSync
        isIncrementalContactSync = !fullSync && since > 0
        isSyncingContacts = true
        sendCommand(MeshCoreProtocol.buildGetContacts(since: since), label: "GET_CONTACTS(since:\(since))")
    }

    func sendAdvertise(type: UInt8 = 0) {
        sendCommand(MeshCoreProtocol.buildSendSelfAdvert(advertType: type), label: "SELF_ADVERT")
    }

    // MARK: - Favourites

    /// Contacts sorted with favourites first, then alphabetical.
    var sortedContacts: [Contact] {
        contacts.sorted { a, b in
            if a.isFavourite != b.isFavourite {
                return a.isFavourite
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Toggle favourite flag on a contact and sync to the radio.
    func toggleFavourite(for contact: Contact) {
        var newFlags = contact.flags
        if contact.isFavourite {
            newFlags &= ~0x01  // Clear bit 0
        } else {
            newFlags |= 0x01   // Set bit 0
        }

        // Send CMD_ADD_UPDATE_CONTACT with ALL existing contact data — only flags changed
        let frame = MeshCoreProtocol.buildAddUpdateContact(
            publicKey: contact.publicKey,
            type: contact.type.rawValue,
            flags: newFlags,
            outPathLen: contact.outPathLen,
            outPath: contact.outPath,
            advName: contact.name,
            lastAdvert: contact.lastAdvert,
            latitude: Int32(contact.latitude * 1_000_000),
            longitude: Int32(contact.longitude * 1_000_000)
        )
        sendCommand(frame, label: "UPDATE_CONTACT_FLAGS")

        // Optimistic local update
        if let index = contacts.firstIndex(where: { $0.publicKeyPrefix == contact.publicKeyPrefix }) {
            contacts[index] = contact.withFlags(newFlags)
        }
    }

    /// Update a contact's flags byte and sync to the radio (preserves all other contact data).
    /// Update a contact's routing path via CMD_ADD_UPDATE_CONTACT.
    func setContactPath(_ contact: Contact, pathLen: Int8, pathData: Data) {
        let pathHex = pathData.isEmpty ? "(empty)" : pathData.map { String(format: "%02x", $0) }.joined()
        let mode = pathLen < 0 ? "flood" : pathLen == 0 ? "direct" : "\(pathLen) hops"
        DebugLogger.shared.log("PATH SET: \(mode) pathLen=\(pathLen) pathHex=\(pathHex) for \(contact.name)", level: .tx)

        let frame = MeshCoreProtocol.buildAddUpdateContact(
            publicKey: contact.publicKey,
            type: contact.type.rawValue,
            flags: contact.flags,
            outPathLen: pathLen,
            outPath: pathData,
            advName: contact.name,
            lastAdvert: contact.lastAdvert,
            latitude: Int32(contact.latitude * 1_000_000),
            longitude: Int32(contact.longitude * 1_000_000)
        )
        sendCommand(frame, label: "SET_CONTACT_PATH(len=\(pathLen))")

        // Optimistic local update
        if let index = contacts.firstIndex(where: { $0.publicKeyPrefix == contact.publicKeyPrefix }) {
            contacts[index] = Contact(
                publicKey: contact.publicKey,
                name: contact.name,
                type: contact.type,
                flags: contact.flags,
                outPathLen: pathLen,
                outPath: pathData,
                lastAdvert: contact.lastAdvert,
                latitude: contact.latitude,
                longitude: contact.longitude,
                lastmod: contact.lastmod
            )
        }

        // Request updated contacts after a delay to verify the device accepted the path
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.requestDebouncedIncrementalSync()
        }
    }

    func updateContactFlags(_ contact: Contact, newFlags: UInt8) {
        let frame = MeshCoreProtocol.buildAddUpdateContact(
            publicKey: contact.publicKey,
            type: contact.type.rawValue,
            flags: newFlags,
            outPathLen: contact.outPathLen,
            outPath: contact.outPath,
            advName: contact.name,
            lastAdvert: contact.lastAdvert,
            latitude: Int32(contact.latitude * 1_000_000),
            longitude: Int32(contact.longitude * 1_000_000)
        )
        sendCommand(frame, label: "UPDATE_CONTACT_FLAGS")

        // Optimistic local update
        if let index = contacts.firstIndex(where: { $0.publicKeyPrefix == contact.publicKeyPrefix }) {
            contacts[index] = contact.withFlags(newFlags)
        }
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
        // Update local config so UI reflects the change immediately
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
            self?.setLocationFromPhoneGPS()
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
        // Optimistic local update
        deviceConfig.rxDelayBase = rxDelayBase
        deviceConfig.airtimeFactor = airtimeFactor
        // Read back after 1s to confirm device accepted
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
            self?.requestTuningParams()
        }
    }

    func setOtherParams(manualAddContacts: UInt8, telemetryBase: UInt8, telemetryLocation: UInt8, advertLocPolicy: UInt8, multiACK: UInt8) {
        DebugLogger.shared.log("SET_OTHER_PARAMS: manual=\(manualAddContacts) telBase=\(telemetryBase) telLoc=\(telemetryLocation) advLoc=\(advertLocPolicy) multiACK=\(multiACK)", level: .tx)
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
        // Read back the device time to confirm and update display
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

    // MARK: - Contact Management

    /// Remove a contact from the device. Sends CMD_REMOVE_CONTACT.
    func removeContact(_ contact: Contact) {
        let frame = MeshCoreProtocol.buildRemoveContact(publicKey: contact.publicKey)
        sendCommand(frame, label: "REMOVE_CONTACT")
        // Remove locally
        contacts.removeAll { $0.publicKeyPrefix == contact.publicKeyPrefix }
        messagesByContact.removeValue(forKey: contact.publicKeyPrefix)
        unreadCounts.removeValue(forKey: contact.publicKeyPrefix)
        if case .contact(let key) = sidebarSelection, key == contact.publicKeyPrefix {
            sidebarSelection = nil
        }
    }

    /// Reset the outbound path for a contact. Sends CMD_RESET_PATH.
    /// Sets firmware path_len to 0xFF (flood). Device will auto-discover a direct path on next send.
    func resetPath(for contact: Contact) {
        DebugLogger.shared.log("PATH RESET: \(contact.name) — will flood until path discovered", level: .tx)
        let frame = MeshCoreProtocol.buildResetPath(publicKey: contact.publicKey)
        sendCommand(frame, label: "RESET_PATH")

        // Optimistic local update — set to flood (0xFF = -1 signed)
        if let index = contacts.firstIndex(where: { $0.publicKeyPrefix == contact.publicKeyPrefix }) {
            contacts[index] = Contact(
                publicKey: contact.publicKey,
                name: contact.name,
                type: contact.type,
                flags: contact.flags,
                outPathLen: -1,  // OUT_PATH_UNKNOWN = 0xFF
                outPath: Data(),
                lastAdvert: contact.lastAdvert,
                latitude: contact.latitude,
                longitude: contact.longitude,
                lastmod: contact.lastmod
            )
        }

        // Request updated contacts after a longer delay (5s) to give the firmware
        // time to process the reset before we read back the path value
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self?.requestDebouncedIncrementalSync()
        }
    }

    /// Share a contact's advert on the mesh (zero-hop). Sends CMD_SHARE_CONTACT.
    func shareContact(_ contact: Contact) {
        let frame = MeshCoreProtocol.buildShareContact(publicKey: contact.publicKey)
        sendCommand(frame, label: "SHARE_CONTACT")
    }

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

    /// Last exported contact URL (set when exportedContact response arrives).
    @Published var lastExportedURL: String?

    // MARK: - Channel Import

    /// Parsed channel data pending user confirmation (add vs replace).
    struct PendingChannelImport {
        let name: String
        let secret: Data?
    }

    @Published var pendingChannelImport: PendingChannelImport?
    @Published var showChannelImportOptions = false

    /// Multi-channel import state.
    struct PendingMultiChannelImport {
        let channels: [PendingChannelImport]
        var names: String {
            channels.map(\.name).joined(separator: ", ")
        }
    }

    @Published var pendingMultiChannelImport: PendingMultiChannelImport?
    @Published var showMultiChannelImportOptions = false

    /// Handle a meshcore:// URL — routes to contact or channel import.
    func handleMeshCoreURL(_ urlString: String) {
        if urlString.hasPrefix("meshcore://channels?") {
            // Multi-channel URL (plural)
            if let parsed = parseMultiChannelURL(urlString) {
                pendingMultiChannelImport = parsed
                showMultiChannelImportOptions = true
            }
        } else if urlString.hasPrefix("meshcore://channel?") {
            // Single channel URL
            if let parsed = parseChannelURL(urlString) {
                pendingChannelImport = parsed
                showChannelImportOptions = true
            }
        } else if urlString.hasPrefix("meshcore://") {
            importContact(url: urlString)
        }
    }

    /// Parse a meshcore://channel?name=NAME&secret=HEX URL.
    private func parseChannelURL(_ urlString: String) -> PendingChannelImport? {
        guard let components = URLComponents(string: urlString),
              let nameItem = components.queryItems?.first(where: { $0.name == "name" }),
              let name = nameItem.value, !name.isEmpty else { return nil }

        var secret: Data?
        if let secretHex = components.queryItems?.first(where: { $0.name == "secret" })?.value,
           !secretHex.isEmpty {
            secret = Data(hexString: secretHex)
        }
        return PendingChannelImport(name: name, secret: secret)
    }

    /// Parse a meshcore://channels?data=BASE64_JSON URL containing multiple channels.
    private func parseMultiChannelURL(_ urlString: String) -> PendingMultiChannelImport? {
        guard let components = URLComponents(string: urlString),
              let dataItem = components.queryItems?.first(where: { $0.name == "data" }),
              let base64 = dataItem.value,
              let jsonData = Data(base64Encoded: base64),
              let array = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: String]] else {
            return nil
        }

        var parsed: [PendingChannelImport] = []
        for item in array {
            guard let name = item["name"], !name.isEmpty else { continue }
            let secretHex = item["secret"] ?? ""
            let secret: Data? = secretHex.isEmpty ? nil : Data(hexString: secretHex)
            parsed.append(PendingChannelImport(name: name, secret: secret))
        }
        guard !parsed.isEmpty else { return nil }
        return PendingMultiChannelImport(channels: parsed)
    }

    /// Add a channel to the next available slot.
    func importChannelAdd(_ data: PendingChannelImport) {
        let usedIndices = Set(channels.map(\.index))
        var nextSlot: UInt8 = 1
        while usedIndices.contains(nextSlot) && nextSlot < deviceConfig.maxChannels {
            nextSlot += 1
        }
        setChannel(index: nextSlot, name: data.name, secret: data.secret)
    }

    /// Replace all non-public channels, then add this one at slot 1.
    func importChannelReplaceAll(_ data: PendingChannelImport) {
        // Clear all non-public channels
        for channel in channels where channel.index != 0 {
            setChannel(index: channel.index, name: "", secret: nil)
        }
        // Add the new channel at slot 1
        setChannel(index: 1, name: data.name, secret: data.secret)
    }

    /// Add multiple channels to the next available slots.
    func importMultiChannelsAdd(_ data: PendingMultiChannelImport) {
        var usedIndices = Set(channels.map(\.index))
        for channel in data.channels {
            var nextSlot: UInt8 = 1
            while usedIndices.contains(nextSlot) && nextSlot < deviceConfig.maxChannels {
                nextSlot += 1
            }
            guard nextSlot < deviceConfig.maxChannels else { break }
            setChannel(index: nextSlot, name: channel.name, secret: channel.secret)
            usedIndices.insert(nextSlot)
        }
    }

    /// Replace all non-public channels, then add the imported channels.
    func importMultiChannelsReplace(_ data: PendingMultiChannelImport) {
        // Clear all non-public channels
        for channel in channels where channel.index != 0 {
            setChannel(index: channel.index, name: "", secret: nil)
        }
        // Add each imported channel starting at slot 1
        for (i, channel) in data.channels.enumerated() {
            let slot = UInt8(i + 1)
            guard slot < deviceConfig.maxChannels else { break }
            setChannel(index: slot, name: channel.name, secret: channel.secret)
        }
    }

    // MARK: - Messaging

    func messages(for contact: Contact) -> [Message] {
        messagesByContact[contact.publicKeyPrefix] ?? []
    }

    func unreadCount(for contact: Contact) -> Int {
        unreadCounts[contact.publicKeyPrefix] ?? 0
    }

    func markAsRead(_ contact: Contact) {
        markAsRead(contactKey: contact.publicKeyPrefix)
    }

    func markAsRead(contactKey: Data) {
        unreadCounts[contactKey] = 0
        updateAppBadge()
        let key = "lastRead.\(contactKey.map { String(format: "%02x", $0) }.joined())"
        iCloudStore.set(Date().timeIntervalSince1970, forKey: key)
        iCloudStore.synchronize()
    }

    /// Returns the index of the first unread incoming message for a contact.
    func firstUnreadIndex(in messages: [Message], for contactKey: Data) -> Int? {
        let key = "lastRead.\(contactKey.map { String(format: "%02x", $0) }.joined())"
        let lastRead = iCloudStore.double(forKey: key)
        guard lastRead > 0 else { return nil }
        let lastReadDate = Date(timeIntervalSince1970: lastRead)
        return messages.firstIndex { $0.timestamp > lastReadDate && !$0.isOutgoing }
    }

    /// Returns the last-read timestamp for a contact.
    func lastReadTimestamp(for contactKey: Data) -> Date? {
        let key = "lastRead.\(contactKey.map { String(format: "%02x", $0) }.joined())"
        let ts = iCloudStore.double(forKey: key)
        guard ts > 0 else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    func sendTextMessage(_ text: String, to contact: Contact) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Add message to array BEFORE sending — prevents race where response arrives before message is stored
        let outgoing = Message(
            contactKeyHash: contact.publicKeyPrefix,
            text: trimmed,
            timestamp: Date(),
            isOutgoing: true,
            status: .sending
        )
        messagesByContact[contact.publicKeyPrefix, default: []].append(outgoing)
        persistMessages(for: contact.publicKeyPrefix)

        let frame = MeshCoreProtocol.buildSendTextMessage(
            text: trimmed,
            recipientKeyHash: contact.publicKeyPrefix
        )
        Self.logger.info("DM SEND: to=\(contact.name) key=\(contact.publicKeyPrefix.map { String(format: "%02x", $0) }.joined())")
        DebugLogger.shared.log("DM SEND: to='\(contact.name)' '\(text.prefix(40))'", level: .tx)
        sendCommand(frame, label: "SEND_TXT")
    }

    func sendChannelMessage(_ text: String, channelIndex: UInt8 = 0) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let frame = MeshCoreProtocol.buildSendChannelMessage(
            text: trimmed,
            channelIndex: channelIndex
        )
        Self.logger.info("CHANNEL TX: [\(frame.count) bytes] \(frame.map { String(format: "%02X", $0) }.joined(separator: " "))")
        let connDesc = String(describing: self.connectionState)
        Self.logger.info("CHANNEL TX: cmd=0x\(String(format: "%02X", frame[0])) txtType=\(frame[1]) chIdx=\(frame[2]) text='\(trimmed)' connState=\(connDesc)")
        let frameHex = frame.map { String(format: "%02X", $0) }.joined(separator: " ")
        DebugLogger.shared.log("CH TX: ch=\(frame[2]) [\(frame.count)B] \(frameHex)", level: .tx)
        DebugLogger.shared.log("CH TX: text='\(trimmed)'", level: .tx)
        sendCommand(frame, label: "SEND_CHANNEL_TXT")
        Self.logger.info("CHANNEL TX: frame sent, awaiting RESP_CODE_OK (0x00) or RESP_CODE_ERR (0x01)")

        let channelKey = Data([channelIndex])
        let outgoing = Message(
            contactKeyHash: channelKey,
            text: trimmed,
            timestamp: Date(),
            isOutgoing: true,
            status: .sent,  // Channel messages are fire-and-forget — mark sent immediately
            channelIndex: channelIndex
        )
        messagesByContact[channelKey, default: []].append(outgoing)
        persistMessages(for: channelKey)

        // Echo detection via 0x88 (LOG_RX_DATA) timing correlation.
        // The firmware does NOT deliver our own channel messages back as 0x11.
        // Instead, 0x88 fires when any repeater forwards a packet after our send.
        if UserDefaults.standard.bool(forKey: "channelEchoDetection") {
            pendingChannelEcho = (id: outgoing.id, channelKey: channelKey, sent: Date())
            DebugLogger.shared.log("ECHO: armed pending echo for ch=\(channelIndex)", level: .info)
        }
    }

    func syncNextMessage() {
        isSyncingMessages = true
        sendCommand(MeshCoreProtocol.buildSyncNextMessage(), label: "SYNC_NEXT_MSG")
    }

    // MARK: - Remote Management

    /// Get or create a remote management session for a contact.
    /// Not @Published so this is safe to call during view body evaluation.
    /// Changes to session @Published properties are forwarded to the ViewModel
    /// so the contact list re-renders (badges, lock icons, etc.).
    func remoteSession(for contact: Contact) -> RemoteDeviceSession {
        let key = contact.publicKeyPrefix
        if let existing = remoteSessions[key] {
            return existing
        }
        let session = RemoteDeviceSession(contact: contact)
        remoteSessions[key] = session
        // Forward session changes to ViewModel so contact list updates
        sessionCancellables[key] = session.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        return session
    }

    /// Login to a remote device (repeater/room server).
    func loginToRemoteDevice(_ contact: Contact, password: String, remember: Bool = true) {
        let session = remoteSession(for: contact)
        // Guard against double-sends if already logging in
        if case .loggingIn = session.loginState { return }
        session.loginState = .loggingIn
        pendingLoginPassword = password
        pendingLoginRememberPassword = remember
        let frame = MeshCoreProtocol.buildSendLogin(
            recipientPublicKey: contact.publicKey,
            password: password
        )
        sendCommand(frame, label: "SEND_LOGIN")
    }

    /// Send a CLI command to a remote device. Polls for response after a delay.
    func sendCLICommand(_ command: String, to contact: Contact) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let session = remoteSession(for: contact)
        let cmdIndex = session.commandSent(trimmed)

        // GPS-specific logging
        if trimmed.hasPrefix("gps") {
            Self.logger.info("REMOTE GPS: Sending '\(trimmed)' to \(contact.name)")
        }

        let frame = MeshCoreProtocol.buildSendCLICommand(
            command: trimmed,
            recipientKeyHash: contact.publicKeyPrefix
        )
        sendCommand(frame, label: "CLI_CMD")

        // Poll for response after a short delay — CLI responses go through the offline message queue
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            guard let self else { return }
            self.syncNextMessage()

            // Timeout: if no response after 8 seconds, mark as timed out
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            session.timeoutCommand(at: cmdIndex)

            // Session expiry detection: if 3+ consecutive commands timed out,
            // the remote session has likely expired on the server side
            let recentHistory = session.cliHistory.suffix(3)
            if recentHistory.count >= 3,
               recentHistory.allSatisfy({ $0.response == "(no response)" }),
               case .loggedIn = session.loginState {
                session.loginState = .loginFailed(
                    message: "Session may have expired \u{2014} please login again."
                )
                session.cliHistory = []
                session.settings = [:]
                session.hasLoadedFullSettings = false
                session.isFetchingSettings = false
                session.isWaitingForResponse = false
            }
        }
    }

    /// Log out from a remote device session.
    /// Clears all cached state so re-login starts fresh with a new password.
    func logoutFromRemoteDevice(_ contact: Contact) {
        let session = remoteSession(for: contact)
        // Mark all pending CLI commands as timed out
        for i in session.cliHistory.indices where !session.cliHistory[i].isComplete {
            session.cliHistory[i].response = "(session ended)"
        }
        session.loginState = .notLoggedIn
        session.cliHistory = []
        session.settings = [:]
        session.isFetchingSettings = false
        session.hasLoadedFullSettings = false
        session.isWaitingForResponse = false
        session.fetchReceivedCount = 0
        session.fetchTotalCount = 0
    }

    /// Request status from a remote device.
    func requestRemoteStatus(_ contact: Contact) {
        let frame = MeshCoreProtocol.buildSendStatusReq(
            recipientPublicKey: contact.publicKey
        )
        sendCommand(frame, label: "STATUS_REQ")
    }

    /// Fetch all settings from a remote device sequentially.
    /// Called automatically after login and when management screen opens.
    func fetchRemoteSettings(for contact: Contact) {
        let session = remoteSession(for: contact)
        // Skip if already fetching (prevents race between auto-fetch and .task)
        guard !session.isFetchingSettings else {
            Self.logger.info("REMOTE MGMT: Settings fetch already in progress, skipping duplicate for \(contact.name)")
            return
        }
        session.isFetchingSettings = true
        session.fetchReceivedCount = 0

        let commands = [
            "ver", "clock",
            "get radio", "get tx", "get repeat",
            "get af", "get rxdelay", "get txdelay", "get direct.txdelay",
            "get flood.max", "get int.thresh", "get agc.reset.interval",
            "get name", "get lat", "get lon", "get owner.info",
            "get advert.interval", "get flood.advert.interval", "get multi.acks",
            "get allow.read.only",
            "get adc.multiplier",
            "get loop.detect", "get path.hash.mode",
            "powersaving", "gps", "gps advert",
        ]

        session.fetchTotalCount = commands.count
        Self.logger.info("REMOTE MGMT: Fetching \(commands.count) settings for \(contact.name)")

        Task { [weak self] in
            let batchSize = 3
            for batchStart in stride(from: 0, to: commands.count, by: batchSize) {
                guard let self else { return }
                let batchEnd = min(batchStart + batchSize, commands.count)
                let batch = commands[batchStart..<batchEnd]
                // Send batch concurrently
                await withTaskGroup(of: Void.self) { group in
                    for command in batch {
                        group.addTask {
                            await self.fetchRemoteSetting(command: command, contact: contact, session: session)
                        }
                    }
                }
                session.fetchReceivedCount += batch.count
                // Small delay between batches to avoid overwhelming the BLE buffer
                if batchEnd < commands.count {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            session.isFetchingSettings = false
            session.hasLoadedFullSettings = true
            Self.logger.info("REMOTE MGMT: Finished fetching settings for \(contact.name), received \(session.fetchReceivedCount)/\(commands.count)")
        }
    }

    /// Send a single CLI command during settings fetch, poll for response, wait for it.
    private func fetchRemoteSetting(command: String, contact: Contact, session: RemoteDeviceSession) async {
        let cmdIndex = session.commandSent(command)

        let frame = MeshCoreProtocol.buildSendCLICommand(
            command: command,
            recipientKeyHash: contact.publicKeyPrefix
        )
        Self.logger.debug("REMOTE MGMT: Sending CLI: '\(command)' to \(contact.name)")
        sendCommand(frame, label: "CLI_FETCH")

        // Wait for radio transmission, then poll
        try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
        syncNextMessage()

        // Wait up to 3 seconds for the response to arrive
        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if cmdIndex < session.cliHistory.count && session.cliHistory[cmdIndex].isComplete {
                let response = session.cliHistory[cmdIndex].response ?? "(empty)"
                Self.logger.debug("REMOTE MGMT: Response for '\(command)': '\(response)'")
                return
            }
        }

        // Timeout
        Self.logger.warning("REMOTE MGMT: Timeout for '\(command)' on \(contact.name)")
        session.timeoutCommand(at: cmdIndex)
    }

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

        case .autoAddConfig(let bitmask):
            Self.logger.info("PARSED AutoAddConfig: bitmask=0x\(String(format: "%02x", bitmask))")
            deviceConfig.autoAddBitmask = bitmask

        case .contactsStart(let count):
            Self.logger.info("Contacts sync starting: \(count) contacts expected")
            DebugLogger.shared.log("Contacts sync: \(count) expected", level: .info)
            expectedContactCount = count
            // Clear only the buffer, never the displayed contacts
            incomingContacts = []

        case .contact(let contact):
            Self.logger.debug("Received contact: \(contact.name) type=\(contact.type.rawValue)")
            incomingContacts.append(contact)

        case .endOfContacts(let lastmod):
            Self.logger.info("Contacts sync complete: \(self.incomingContacts.count) contacts, lastmod=\(lastmod), incremental=\(self.isIncrementalContactSync)")
            DebugLogger.shared.log("Contacts done: \(self.incomingContacts.count) synced", level: .info)
            if isIncrementalContactSync {
                // Incremental sync: merge only modified contacts into existing list
                if !incomingContacts.isEmpty {
                    var merged = contacts
                    for incoming in incomingContacts {
                        if let idx = merged.firstIndex(where: { $0.publicKeyPrefix == incoming.publicKeyPrefix }) {
                            merged[idx] = incoming
                        } else {
                            merged.append(incoming)
                        }
                    }
                    contacts = merged
                }
                // If 0 results, don't touch contacts — nothing changed
            } else {
                // Full sync: atomic swap — replace entire list at once
                contacts = incomingContacts
            }
            incomingContacts = []
            lastContactsSync = lastmod
            isIncrementalContactSync = false
            isSyncingContacts = false

            #if canImport(CoreSpotlight)
            indexContactsForSpotlight()
            #endif

            // Only sync channels on full sync (initial connection), not incremental
            // (path changes, adverts, etc. don't affect channels)
            if !hasCompletedInitialChannelSync {
                syncChannels()
                hasCompletedInitialChannelSync = true
            }

        case .sent(let type, let expectedACK, let suggestedTimeout):
            Self.logger.info("PARSED Sent: type=\(type) expectedACK=\(expectedACK) timeout=\(suggestedTimeout)ms")
            DebugLogger.shared.log("Sent: type=\(type == 0 ? "direct" : "flood") ack=\(expectedACK) timeout=\(suggestedTimeout)ms", level: .rx)
            handleSentResponse(expectedACK: expectedACK, suggestedTimeoutMs: suggestedTimeout)

        case .contactMsgRecv(let message):
            Self.logger.info("Received direct message: \(message.text)")
            DebugLogger.shared.log("DM RX: '\(message.text.prefix(60))'", level: .rx)
            handleIncomingMessage(message)
            if isSyncingMessages {
                syncNextMessage()
            }

        case .channelMsgRecv(let message):
            Self.logger.info("CHANNEL RX: ch=\(message.channelIndex ?? 0) isOutgoing=\(message.isOutgoing) sender='\(message.senderName ?? "?")' text='\(message.text.prefix(40))'")
            DebugLogger.shared.log("CH RX: ch=\(message.channelIndex ?? 0) from='\(message.senderName ?? "?")' '\(message.text.prefix(40))'", level: .rx)
            handleIncomingMessage(message)
            if isSyncingMessages {
                syncNextMessage()
            }

        case .noMoreMessages:
            Self.logger.debug("No more messages")
            isSyncingMessages = false

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
            Self.logger.info("PUSH NewAdvert (manual_add): \(contact.name)")
            DebugLogger.shared.log("PUSH NewAdvert: \(contact.name)", level: .rx)
            // Add to pending contacts list for user approval
            if !pendingNewContacts.contains(where: { $0.publicKeyPrefix == contact.publicKeyPrefix }) {
                pendingNewContacts.append(contact)
                if isInBackground && NotificationPreferences.shared.notifyNewContacts {
                    postEventNotification(title: "New Contact Discovered", body: contact.name, threadId: "contacts")
                }
            }
            // Also show as discovered node during discover scan
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
            traceTimeoutTask?.cancel()
            lastTraceResult = result
            pendingTraceTag = nil
            // Auto-open contact detail to show trace result
            if let contact = pendingTraceContact {
                detailContactForTrace = contact
            }
            pendingTraceContact = nil

        case .telemetryResponse(let senderKey, let readings):
            Self.logger.info("PUSH Telemetry: \(readings.count) readings from \(senderKey.prefix(6).map { String(format: "%02x", $0) }.joined())")
            telemetryTimeoutTask?.cancel()
            telemetryByContact[senderKey] = readings
            if pendingTelemetryKey == senderKey { pendingTelemetryKey = nil }

        case .controlData(let snr, let rssi, let pathLen, let payload):
            Self.logger.info("PUSH ControlData: snr=\(snr) rssi=\(rssi) pathLen=\(pathLen)")
            handleControlData(snr: snr, rssi: rssi, pathLen: pathLen, payload: payload)

        case .channelInfo(let channel):
            let secretDesc = channel.secret.map { $0.map { String(format: "%02x", $0) }.joined() } ?? "none"
            Self.logger.info("Channel info: idx=\(channel.index) name='\(channel.name)' secret=\(secretDesc)")
            DebugLogger.shared.log("CH[\(channel.index)]: '\(channel.name)' secret=\(channel.secret != nil ? "\(channel.secret!.count)B" : "none")", level: .rx)
            handleChannelInfo(channel)

        case .exportedContact(let url):
            Self.logger.info("EXPORT RESP: url='\(url.prefix(80))' (\(url.count) chars)")
            DebugLogger.shared.log("EXPORT: \(url.count) chars → \(url.prefix(60))...", level: .rx)
            if url.isEmpty {
                Self.logger.warning("EXPORT RESP: empty URL — device returned no card data")
            }
            lastExportedURL = url

        case .advertPath(let info):
            Self.logger.info("AdvertPath: timestamp=\(info.recvTimestamp) pathLen=\(info.pathLen)")
            // Store for the contact that was queried
            handleAdvertPathResponse(info)

        case .allowedRepeatFreq(let ranges):
            Self.logger.info("AllowedRepeatFreq: \(ranges.count) ranges")
            allowedRepeatFreqRanges = ranges

        case .currentAdvert(let adData):
            Self.logger.debug("Current advert: \(adData.count) bytes")

        case .rawData(let pktData):
            Self.logger.debug("Raw data: \(pktData.count) bytes")

        case .contactDeleted(let publicKey):
            let keyPrefix = publicKey.prefix(6)
            let name = contacts.first(where: { $0.publicKeyPrefix == keyPrefix })?.name ?? "Unknown"
            Self.logger.info("Contact deleted by device: \(name)")
            contacts.removeAll { $0.publicKeyPrefix == keyPrefix }
            lastErrorMessage = "Contact \"\(name)\" was removed from device to make room for new contacts."

        case .contactsFull(let maxContacts):
            Self.logger.warning("Contact storage full: \(maxContacts)")
            lastErrorMessage = "Contact storage is full (\(maxContacts) contacts). New contacts cannot be added."
            postEventNotification(title: "Contact Storage Full", body: "Device has reached \(maxContacts) contacts. New contacts cannot be added.", threadId: "system")

        case .unknown(let type, let payload):
            if type == 0x88 {
                // PUSH_CODE_LOG_RX_DATA — raw LoRa packet received by device
                let snr = payload.count > 0 ? Int8(bitPattern: payload[0]) : 0
                let rssi = payload.count > 1 ? Int8(bitPattern: payload[1]) : 0
                Self.logger.debug("LOG_RX_DATA (0x88): snr=\(Float(snr)/4.0) rssi=\(rssi) rawLen=\(payload.count - 2)")

                // Echo detection via 0x88 timing correlation.
                // If a LOG_RX_DATA arrives within 30s of our channel send,
                // a repeater forwarded our message → mark as .repeated.
                if let pending = pendingChannelEcho {
                    let elapsed = Date().timeIntervalSince(pending.sent)
                    if elapsed < 30 {
                        if var msgs = messagesByContact[pending.channelKey],
                           let msgIdx = msgs.firstIndex(where: { $0.id == pending.id }) {
                            Self.logger.info("ECHO: 0x88 received \(String(format: "%.1f", elapsed))s after channel send — marking as repeated")
                            DebugLogger.shared.log("ECHO: repeated after \(String(format: "%.1f", elapsed))s (snr=\(String(format: "%.1f", Float(snr)/4.0)))", level: .info)
                            msgs[msgIdx].status = .repeated
                            messagesByContact[pending.channelKey] = msgs
                            persistMessages(for: pending.channelKey)
                        }
                        pendingChannelEcho = nil
                    } else {
                        // Expired — clear stale pending echo
                        pendingChannelEcho = nil
                    }
                }
            } else if type >= 0x80 {
                Self.logger.debug("Ignoring push notification 0x\(String(format: "%02x", type)), \(payload.count) bytes payload")
            } else {
                Self.logger.warning("Unhandled response 0x\(String(format: "%02x", type)), \(payload.count) bytes payload")
            }
        }
    }

    /// Handle RESP_CODE_SENT — device accepted our message. Mark as .sent and track ACK.
    private func handleSentResponse(expectedACK: UInt32, suggestedTimeoutMs: UInt32) {
        // Check if this SENT is for a pending login attempt
        let hasLoginPending = remoteSessions.values.contains(where: {
            if case .loggingIn = $0.loginState { return true }
            return false
        })
        if hasLoginPending {
            let timeoutMs = UInt64(suggestedTimeoutMs) + 3000 // suggested + 3s buffer
            loginTimeoutTask?.cancel()
            loginTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
                guard !Task.isCancelled, let self else { return }
                for (_, session) in self.remoteSessions {
                    if case .loggingIn = session.loginState {
                        session.loginState = .loginFailed(
                            message: "Login timed out \u{2014} the device did not respond. Check your password and make sure the device is in range."
                        )
                        break
                    }
                }
            }
        }

        var matched = false
        for (contactKey, messages) in messagesByContact {
            if let idx = messages.lastIndex(where: { $0.isOutgoing && ($0.status == .sending || $0.status == .retrying || $0.status == .flooding) }) {
                Self.logger.info("DM RESP_SENT: matched message \(messages[idx].id) for contact \(contactKey.map { String(format: "%02x", $0) }.joined()) → .sent, ack=\(expectedACK)")
                messagesByContact[contactKey]![idx].status = .sent
                messagesByContact[contactKey]![idx].expectedACK = expectedACK
                messagesByContact[contactKey]![idx].suggestedTimeoutMs = suggestedTimeoutMs
                pendingACKs[expectedACK] = (contactKeyHash: contactKey, messageID: messages[idx].id)
                persistMessages(for: contactKey)
                matched = true

                let timeoutSec = max(UInt64(suggestedTimeoutMs / 1000), 30)
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: timeoutSec * 1_000_000_000)
                    guard let self else { return }
                    if self.pendingACKs[expectedACK] != nil {
                        self.handleACKTimeout(ackCode: expectedACK)
                    }
                }
                break
            }
        }
        if !matched {
            Self.logger.warning("DM RESP_SENT: NO .sending message found for ack=\(expectedACK)")
        }
    }

    /// Handle PUSH_CODE_SEND_CONFIRMED — recipient ACKed our message.
    private func handleSendConfirmed(ackCode: UInt32, roundTripMs: UInt32) {
        guard let pending = pendingACKs.removeValue(forKey: ackCode) else {
            Self.logger.warning("DM CONFIRMED: no pending ACK for code \(ackCode)")
            return
        }

        if var messages = messagesByContact[pending.contactKeyHash],
           let idx = messages.firstIndex(where: { $0.id == pending.messageID }) {
            Self.logger.info("DM CONFIRMED: message \(pending.messageID) → .delivered, roundTrip=\(roundTripMs)ms")
            messages[idx].status = .delivered
            messages[idx].roundTripMs = roundTripMs
            messagesByContact[pending.contactKeyHash] = messages
            persistMessages(for: pending.contactKeyHash)
        }
    }

    /// Handle ACK timeout — auto-retry on direct path, then flood fallback if enabled.
    private func handleACKTimeout(ackCode: UInt32) {
        guard let pending = pendingACKs.removeValue(forKey: ackCode) else { return }

        guard var messages = messagesByContact[pending.contactKeyHash],
              let idx = messages.firstIndex(where: { $0.id == pending.messageID }),
              messages[idx].status == .sent else { return }

        let message = messages[idx]
        let autoRetry = UserDefaults.standard.bool(forKey: "autoRetry")
        let autoResetPath = UserDefaults.standard.bool(forKey: "autoResetPath")
        let maxDirectRetries: UInt8 = 3
        let maxFloodRetries: UInt8 = 2

        // Phase 1: Direct path retries (attempts 0-2 = 3 tries total)
        if !message.didResetPath && message.attempt < maxDirectRetries - 1 {
            if autoRetry {
                Self.logger.info("ACK timeout for message \(pending.messageID), auto-retrying (attempt \(message.attempt + 1))")
                messages[idx].status = .retrying
                messages[idx].attempt += 1
                let attempt = messages[idx].attempt
                let contactKey = pending.contactKeyHash
                messagesByContact[contactKey] = messages
                persistMessages(for: contactKey)

                // Re-send on direct path
                if let channelIdx = message.channelIndex {
                    let frame = MeshCoreProtocol.buildSendChannelMessage(
                        text: message.text,
                        channelIndex: channelIdx
                    )
                    sendCommand(frame, label: "AUTO_RETRY_CHANNEL(\(attempt))")
                } else {
                    let frame = MeshCoreProtocol.buildSendTextMessage(
                        text: message.text,
                        recipientKeyHash: contactKey,
                        attempt: attempt
                    )
                    sendCommand(frame, label: "AUTO_RETRY_TXT(\(attempt))")
                }
                return
            }
        }

        // Phase 2: Reset path and flood (if enabled and not already flooding)
        if autoRetry && autoResetPath && !message.didResetPath && message.channelIndex == nil {
            Self.logger.info("Direct retries exhausted for \(pending.messageID), resetting path and flooding")
            messages[idx].status = .flooding
            messages[idx].didResetPath = true
            messages[idx].attempt = 0 // Reset attempt counter for flood phase
            let contactKey = pending.contactKeyHash
            messagesByContact[contactKey] = messages
            persistMessages(for: contactKey)

            // Find the contact to reset path
            if let contact = contacts.first(where: { $0.publicKeyPrefix == contactKey }) {
                resetPath(for: contact)
            }

            // Delay before flood send to allow path reset to take effect
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                let frame = MeshCoreProtocol.buildSendTextMessage(
                    text: message.text,
                    recipientKeyHash: contactKey,
                    attempt: 0
                )
                self.sendCommand(frame, label: "FLOOD_RETRY_TXT")
            }
            return
        }

        // Phase 3: Flood retries (didResetPath = true, retry within flood phase)
        if message.didResetPath && message.attempt < maxFloodRetries - 1 {
            if autoRetry {
                Self.logger.info("Flood retry for \(pending.messageID) (attempt \(message.attempt + 1))")
                messages[idx].status = .flooding
                messages[idx].attempt += 1
                let attempt = messages[idx].attempt
                let contactKey = pending.contactKeyHash
                messagesByContact[contactKey] = messages
                persistMessages(for: contactKey)

                let frame = MeshCoreProtocol.buildSendTextMessage(
                    text: message.text,
                    recipientKeyHash: contactKey,
                    attempt: attempt
                )
                sendCommand(frame, label: "FLOOD_RETRY_TXT(\(attempt))")
                return
            }
        }

        // All retries exhausted — mark as failed
        Self.logger.info("All retries exhausted for message \(pending.messageID), marking as failed")
        messages[idx].status = .failed
        messagesByContact[pending.contactKeyHash] = messages
        persistMessages(for: pending.contactKeyHash)
    }

    /// Delete a single message from local storage and iCloud.
    func deleteMessage(_ message: Message, in contactKey: Data) {
        if var messages = messagesByContact[contactKey],
           let idx = messages.firstIndex(where: { $0.id == message.id }) {
            messages.remove(at: idx)
            messagesByContact[contactKey] = messages
            persistMessages(for: contactKey)
        }
    }

    /// Clear all messages for all contacts.
    func clearAllMessages() {
        messagesByContact.removeAll()
        messageStore.deleteAllMessages()
        unreadCounts.removeAll()
        updateAppBadge()
    }

    /// Clear all saved message drafts from iCloud.
    func clearAllDrafts() {
        let store = NSUbiquitousKeyValueStore.default
        let keys = store.dictionaryRepresentation.keys.filter { $0.hasPrefix("draft.") }
        for key in keys {
            store.removeObject(forKey: key)
        }
        store.synchronize()
    }

    /// Retry sending a failed message. Restarts the full retry flow.
    func retryMessage(_ message: Message) {
        guard message.isOutgoing, message.status == .failed else { return }
        let contactKey = message.contactKeyHash

        if var messages = messagesByContact[contactKey],
           let idx = messages.firstIndex(where: { $0.id == message.id }) {

            // If this is a DM that already failed, reset path and flood
            if message.channelIndex == nil {
                // Reset path so the device floods instead of using the stale direct route
                if let contact = contacts.first(where: { $0.publicKeyPrefix == contactKey }) {
                    Self.logger.info("RETRY: resetting path for \(contact.name) before flood retry")
                    resetPath(for: contact)
                }
                messages[idx].status = .sending  // Must be .sending so handleSentResponse can match
                messages[idx].attempt = 2
                messages[idx].didResetPath = true
                messagesByContact[contactKey] = messages

                // Delay to let path reset take effect, then send as flood
                let msgID = message.id
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard let self else { return }
                    Self.logger.info("RETRY: sending flood for \(msgID) with attempt=2")
                    let frame = MeshCoreProtocol.buildSendTextMessage(
                        text: message.text,
                        recipientKeyHash: contactKey,
                        attempt: 2
                    )
                    self.sendCommand(frame, label: "MANUAL_RETRY_FLOOD")
                }
            } else {
                // Channel message retry — just resend
                messages[idx].status = .sending
                messages[idx].attempt = 0
                messagesByContact[contactKey] = messages
                let frame = MeshCoreProtocol.buildSendChannelMessage(
                    text: message.text,
                    channelIndex: message.channelIndex!
                )
                sendCommand(frame, label: "MANUAL_RETRY_CHANNEL")
            }
            persistMessages(for: contactKey)
        }
    }

    /// Handle PUSH_CODE_ADVERT — a contact advertised on the mesh.
    /// Update the existing contact or add a new one. No need to trigger
    /// CMD_GET_CONTACTS — the advert itself contains the full contact data.
    private func handleAdvert(_ contact: Contact) {
        if let idx = contacts.firstIndex(where: { $0.publicKeyPrefix == contact.publicKeyPrefix }) {
            contacts[idx] = contact
        } else {
            contacts.append(contact)
        }

        // If discover is active (fallback mode), also show as discovered node
        if isDiscovering {
            addAdvertAsDiscoveredNode(contact)
        }
    }

    /// Convert a Contact from an advert push into a DiscoveredNode for the discover list.
    private func addAdvertAsDiscoveredNode(_ contact: Contact) {
        // Filter self-adverts
        let selfKeyHex = deviceConfig.publicKeyHex
        let contactKeyHex = contact.publicKeyPrefix.map { String(format: "%02x", $0) }.joined()
        if !selfKeyHex.isEmpty && selfKeyHex.hasPrefix(contactKeyHex) { return }

        let node = DiscoveredNode(
            publicKey: Data(contact.publicKeyPrefix),
            name: contact.name,
            type: contact.type,
            snr: 0,
            rssi: 0,
            pathLen: UInt8(clamping: contact.outPathLen),
            latitude: contact.latitude,
            longitude: contact.longitude
        )
        if let idx = discoveredNodes.firstIndex(where: { $0.publicKey == node.publicKey }) {
            discoveredNodes[idx] = node
        } else {
            discoveredNodes.append(node)
        }
    }

    /// Handle login success — find the session that was logging in and update it.
    private func handleLoginSuccess(permissionLevel: Int) {
        loginTimeoutTask?.cancel()
        loginTimeoutTask = nil
        let permission = RemotePermission(rawValue: permissionLevel) ?? .guest
        for (key, session) in remoteSessions {
            if case .loggingIn = session.loginState {
                session.loginState = .loggedIn(permission: permission)

                // Save password to Keychain if user opted in
                if pendingLoginRememberPassword, let password = pendingLoginPassword,
                   let contact = contacts.first(where: { $0.publicKeyPrefix == key }) {
                    let type = permission.isAdmin ? "admin" : "guest"
                    KeychainManager.savePassword(password, forDevice: contact.publicKey, type: type)
                }
                pendingLoginPassword = nil
                pendingLoginRememberPassword = false

                // Sync stored messages first (room server pushes last 32 messages)
                syncNextMessage()
                if let contact = contacts.first(where: { $0.publicKeyPrefix == key }) {
                    // Auto-fetch full settings after login — brief delay to let message sync start
                    Self.logger.info("REMOTE MGMT: Login success for \(contact.name), scheduling settings fetch")
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s
                        guard let self else { return }
                        Self.logger.info("REMOTE MGMT: Starting auto-fetch settings for \(contact.name)")
                        self.fetchRemoteSettings(for: contact)
                    }
                }
                return
            }
        }
    }

    /// Handle login failure.
    private func handleLoginFail() {
        loginTimeoutTask?.cancel()
        loginTimeoutTask = nil
        for (key, session) in remoteSessions {
            if case .loggingIn = session.loginState {
                session.loginState = .loginFailed(message: "Login failed \u{2014} incorrect password.")
                // Delete stale credential from Keychain
                if let contact = contacts.first(where: { $0.publicKeyPrefix == key }) {
                    KeychainManager.deleteAllPasswords(forDevice: contact.publicKey)
                }
                pendingLoginPassword = nil
                pendingLoginRememberPassword = false
                return
            }
        }
    }

    /// Handle RESP_CODE_ERR — stop any pending operations and surface error to user.
    private func handleErrorResponse(code: UInt8, description: String) {
        // Stop login spinner if a login was in progress
        for (_, session) in remoteSessions {
            if case .loggingIn = session.loginState {
                loginTimeoutTask?.cancel()
                loginTimeoutTask = nil
                session.loginState = .loginFailed(message: description)
                break
            }
        }

        // If a path request was pending and got "Unsupported command", provide fallback
        if let key = pendingAdvertPathKey {
            pendingAdvertPathKey = nil
            if let contact = contacts.first(where: { $0.publicKeyPrefix == key }) {
                buildFallbackPath(for: contact)
                return // Don't show the raw error — we handled it gracefully
            }
        }

        // If a discover scan was in progress and got unsupported, fall back to flood advert
        if isDiscovering && code == 1 && description.lowercased().contains("unsupported") {
            discoverUnsupported = true
            startDiscoverFallback()
            return
        }

        // Friendly message for unsupported commands
        if code == 1 && description.lowercased().contains("unsupported") {
            lastErrorMessage = "This command is not supported on the current firmware version."
        } else {
            lastErrorMessage = description
        }
    }

    /// Send a plain text message to a room server (appears in room chat, not CLI).
    func sendRoomMessage(_ text: String, to contact: Contact) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Send as TXT_TYPE_PLAIN (0) — regular room chat post
        let frame = MeshCoreProtocol.buildSendTextMessage(
            text: trimmed,
            recipientKeyHash: contact.publicKeyPrefix,
            txtType: 0
        )
        sendCommand(frame, label: "SEND_ROOM_TXT")

        let outgoing = Message(
            contactKeyHash: contact.publicKeyPrefix,
            text: trimmed,
            timestamp: Date(),
            isOutgoing: true,
            status: .sending
        )
        messagesByContact[contact.publicKeyPrefix, default: []].append(outgoing)
        persistMessages(for: contact.publicKeyPrefix)
    }

    /// Handle an incoming message (direct or channel).
    private func handleIncomingMessage(_ message: Message) {
        let contactKey = message.contactKeyHash

        // Check if this is from a managed device we're logged into
        if let session = remoteSessions[contactKey], !message.isOutgoing {
            if case .loggedIn = session.loginState {
                // txt_type=1 (CLI_DATA) always goes to management screen
                if message.txtType == 1 {
                    Self.logger.info("CLI response (txtType=1) → management: '\(message.text)'")
                    // Strip "> " prefix that room servers add to CLI responses
                    let responseText = message.text.hasPrefix("> ")
                        ? String(message.text.dropFirst(2))
                        : message.text
                    // GPS-specific logging
                    if let pending = session.oldestPendingCommand, pending.hasPrefix("gps") {
                        Self.logger.info("REMOTE GPS: Response: '\(responseText)'")
                    }
                    session.responseReceived(responseText)
                    return
                }
                // txt_type=0 with pending CLI commands — might be a CLI response without the flag
                if session.hasPendingCLICommands || session.isFetchingSettings {
                    Self.logger.info("Routing to CLI (pending commands): '\(message.text)'")
                    let responseText = message.text.hasPrefix("> ")
                        ? String(message.text.dropFirst(2))
                        : message.text
                    session.responseReceived(responseText)
                    return
                }
                // txt_type=0 with no pending CLI commands:
                // Room servers → room chat message, fall through
                // Repeaters → no chat, discard
                if session.contact.type == .room {
                    Self.logger.info("Room chat message: '\(message.text)'")
                    // Fall through to store as normal message
                } else {
                    Self.logger.info("Discarding non-CLI message from repeater")
                    return
                }
            }
        }

        let existing = messagesByContact[contactKey] ?? []
        let isDuplicate = existing.contains { msg in
            msg.text == message.text &&
            abs(msg.timestamp.timeIntervalSince(message.timestamp)) < 2 &&
            msg.isOutgoing == message.isOutgoing
        }
        guard !isDuplicate else {
            Self.logger.debug("Skipping duplicate message")
            return
        }

        messagesByContact[contactKey, default: []].append(message)
        persistMessages(for: contactKey)

        if !isInBackground {
            playReceiveHaptic()
        }

        if selectedContact?.publicKeyPrefix != contactKey {
            unreadCounts[contactKey, default: 0] += 1
            updateAppBadge()
        }

        postLocalNotification(for: message)
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

    // MARK: - Discover

    /// Start a discover scan. Tries CMD_SEND_CONTROL_DATA first; if unsupported,
    /// falls back to flood advertisement and listens for PUSH_CODE_ADVERT responses.
    func startDiscover() {
        discoveredNodes = []
        isDiscovering = true
        discoverFallbackMessage = nil

        if discoverUnsupported {
            // Already know this firmware doesn't support active discover — go straight to fallback
            startDiscoverFallback()
        } else {
            let frame = MeshCoreProtocol.buildSendDiscover()
            sendCommand(frame, label: "DISCOVER_REQ")

            // Auto-stop after 30 seconds (longer to allow for fallback trigger)
            discoverTimeoutTask?.cancel()
            discoverTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled, let self, self.isDiscovering else { return }
                self.isDiscovering = false
            }
        }
    }

    /// Stop the current discover scan.
    func stopDiscover() {
        discoverTimeoutTask?.cancel()
        isDiscovering = false
        DebugLogger.shared.log("DISCOVER: stopped by user", level: .info)
    }

    /// Fallback discover: send flood advertisement and listen for advert responses.
    private func startDiscoverFallback() {
        discoverFallbackMessage = "Using advertisement-based discovery (firmware does not support active discover scan)"
        sendCommand(MeshCoreProtocol.buildSendSelfAdvert(advertType: 1), label: "FLOOD_ADVERT_DISCOVER")

        // Listen for 30 seconds
        discoverTimeoutTask?.cancel()
        discoverTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled, let self, self.isDiscovering else { return }
            self.isDiscovering = false
        }
    }

    /// Handle PUSH_CODE_CONTROL_DATA — parse discover responses from the payload.
    private func handleControlData(snr: Int8, rssi: Int8, pathLen: UInt8, payload: Data) {
        // Discover response payload: sub_type(1) sender_pub_key(32) sender_type(1) sender_name(32 null-term) lat(int32) lon(int32)
        guard payload.count >= 2 else { return }
        let subType = payload[0]

        // 0x81 = DISCOVER_RESP
        guard subType == 0x81 else {
            Self.logger.debug("Control data sub_type=0x\(String(format: "%02x", subType)) — not a discover response")
            return
        }

        var offset = 1
        let keyLen = min(32, payload.count - offset)
        guard keyLen >= 6 else { return }
        let publicKey = Data(payload[offset..<offset+keyLen])
        offset += keyLen

        let contactType: ContactType
        if offset < payload.count {
            contactType = ContactType(rawValue: payload[offset]) ?? .unknown
            offset += 1
        } else {
            contactType = .unknown
        }

        let name: String
        if offset + 32 <= payload.count {
            let nameSlice = payload[offset..<offset+32]
            if let nullIdx = nameSlice.firstIndex(of: 0x00) {
                name = String(data: Data(payload[offset..<nullIdx]), encoding: .utf8) ?? ""
            } else {
                name = String(data: Data(nameSlice), encoding: .utf8) ?? ""
            }
            offset += 32
        } else if offset < payload.count {
            name = String(data: Data(payload[offset...]), encoding: .utf8)?
                .trimmingCharacters(in: .controlCharacters) ?? ""
            offset = payload.count
        } else {
            name = ""
        }

        var latitude: Double = 0
        var longitude: Double = 0
        if offset + 8 <= payload.count {
            var latRaw: Int32 = 0
            _ = withUnsafeMutableBytes(of: &latRaw) { dest in
                payload.copyBytes(to: dest, from: offset..<offset+4)
            }
            latitude = Double(Int32(littleEndian: latRaw)) / 1_000_000.0
            offset += 4
            var lonRaw: Int32 = 0
            _ = withUnsafeMutableBytes(of: &lonRaw) { dest in
                payload.copyBytes(to: dest, from: offset..<offset+4)
            }
            longitude = Double(Int32(littleEndian: lonRaw)) / 1_000_000.0
            offset += 4
        }

        // Filter out our own device (self-advert reflection)
        let selfKeyHex = deviceConfig.publicKeyHex
        let nodeKeyHex = publicKey.prefix(6).map { String(format: "%02x", $0) }.joined()
        if !selfKeyHex.isEmpty && selfKeyHex.hasPrefix(nodeKeyHex) {
            Self.logger.debug("Discover: filtered self-advert (\(name))")
            return
        }

        // Filter out nodes with empty name and zero signal (malformed)
        if name.isEmpty && snr == 0 && rssi == 0 {
            Self.logger.debug("Discover: filtered zero-signal unnamed node")
            return
        }

        let node = DiscoveredNode(
            publicKey: publicKey,
            name: name,
            type: contactType,
            snr: snr,
            rssi: rssi,
            pathLen: pathLen,
            latitude: latitude,
            longitude: longitude
        )

        if let idx = discoveredNodes.firstIndex(where: { $0.publicKey == publicKey }) {
            discoveredNodes[idx] = node
        } else {
            discoveredNodes.append(node)
        }

        Self.logger.info("Discovered: '\(name)' type=\(contactType.rawValue) snr=\(snr) rssi=\(rssi)")
    }

    // MARK: - Trace Route

    /// Send a trace route request to a contact.
    func traceRoute(to contact: Contact) {
        // Trace route only works for multi-hop paths
        guard contact.outPathLen > 0, !contact.outPath.isEmpty else {
            lastErrorMessage = contact.outPathLen == 0
                ? "This contact is a direct neighbor — no route to trace."
                : "No path known for this contact — cannot trace route."
            return
        }
        let tag = UInt32.random(in: 0..<UInt32.max)
        pendingTraceTag = tag
        pendingTraceContact = contact
        lastTraceResult = nil
        // Only send the actual path bytes (outPathLen), not zero-padded data
        let actualPathLen = Int(contact.outPathLen)
        let pathData = contact.outPath.prefix(actualPathLen)
        let frame = MeshCoreProtocol.buildSendTracePath(outPath: Data(pathData), tag: tag)
        sendCommand(frame, label: "TRACE_PATH")

        // Timeout after 15 seconds — cancellable when response arrives
        traceTimeoutTask?.cancel()
        traceTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, let self, self.pendingTraceTag == tag else { return }
            self.pendingTraceTag = nil
            if self.lastTraceResult == nil {
                self.lastErrorMessage = "Trace route timed out — the path may not be reachable."
            }
        }
    }

    // MARK: - Status & Telemetry

    /// Request status from a remote device (repeater/sensor).
    func requestStatus(for contact: Contact) {
        // Log contextual info — status requests are best supported by repeaters, room servers, and sensors
        switch contact.type {
        case .chat:
            Self.logger.info("Status request to chat contact — may not respond")
        case .repeater:
            Self.logger.info("Requesting status from repeater \(contact.name)")
        case .room:
            Self.logger.info("Requesting status from room server \(contact.name)")
        default:
            Self.logger.info("Requesting status from \(contact.name)")
        }

        let key = contact.publicKeyPrefix
        pendingStatusKey = key
        let frame = MeshCoreProtocol.buildSendStatusReq(recipientPublicKey: contact.publicKey)
        sendCommand(frame, label: "STATUS_REQ")

        // Timeout after 15 seconds — cancellable when response arrives
        statusTimeoutTask?.cancel()
        statusTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, let self, self.pendingStatusKey == key else { return }
            self.pendingStatusKey = nil
            if self.statusByContact[key] == nil {
                self.lastErrorMessage = contact.type == .chat
                    ? "No status response — status requests are only supported by repeaters, room servers, and sensors."
                    : "No status response — the device may be out of range or powered off."
            }
        }
    }

    /// Request telemetry from a sensor contact.
    func requestTelemetry(for contact: Contact) {
        DebugLogger.shared.log("TELEMETRY REQ: requesting from \(contact.name)", level: .tx)
        let key = contact.publicKeyPrefix
        pendingTelemetryKey = key
        let frame = MeshCoreProtocol.buildSendTelemetryReq(recipientPublicKey: contact.publicKey)
        sendCommand(frame, label: "TELEMETRY_REQ")

        // Timeout after 15 seconds — cancellable when response arrives
        telemetryTimeoutTask?.cancel()
        telemetryTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, let self, self.pendingTelemetryKey == key else { return }
            self.pendingTelemetryKey = nil
            if self.telemetryByContact[key] == nil {
                // Contextual timeout message based on node type
                switch contact.type {
                case .chat:
                    self.lastErrorMessage = "No telemetry response — telemetry is typically only available from sensor nodes."
                case .room:
                    self.lastErrorMessage = "No telemetry response — room servers don't typically support telemetry."
                default:
                    self.lastErrorMessage = "No telemetry response — the node may not support telemetry or is out of range."
                }
            }
        }
    }

    /// Handle status response — associate with the most recently requested contact.
    private func handleStatusResponse(_ info: RemoteStatusInfo) {
        statusTimeoutTask?.cancel()
        if let key = pendingStatusKey {
            statusByContact[key] = info
            pendingStatusKey = nil
        }
    }

    // MARK: - Advert Path

    /// Request the last known path to a contact.
    /// Falls back to the contact's stored out_path if the firmware doesn't support the command.
    func requestAdvertPath(for contact: Contact) {
        pendingAdvertPathKey = contact.publicKeyPrefix
        let frame = MeshCoreProtocol.buildGetAdvertPath(publicKey: contact.publicKey)
        sendCommand(frame, label: "GET_ADVERT_PATH")

        // Timeout after 10 seconds — fall back to stored path info, cancellable when response arrives
        let key = contact.publicKeyPrefix
        pathTimeoutTask?.cancel()
        pathTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, let self, self.pendingAdvertPathKey == key else { return }
            self.pendingAdvertPathKey = nil
            // Fall back to locally-known path from contact data
            if self.advertPathByContact[key] == nil {
                self.buildFallbackPath(for: contact)
            }
        }
    }

    /// Build path info from the contact's stored out_path when the firmware doesn't support CMD_GET_ADVERT_PATH.
    private func buildFallbackPath(for contact: Contact) {
        let key = contact.publicKeyPrefix
        if contact.outPathLen > 0, !contact.outPath.isEmpty {
            // Parse out_path into 6-byte hop hashes
            var hops: [Data] = []
            var offset = 0
            while offset + 6 <= contact.outPath.count {
                hops.append(Data(contact.outPath[offset..<offset+6]))
                offset += 6
            }
            let info = AdvertPathInfo(
                recvTimestamp: contact.lastAdvert,
                pathLen: UInt8(hops.count),
                pathHashes: hops
            )
            advertPathByContact[key] = info
        } else if contact.outPathLen == 0 {
            // Direct contact — show as zero-hop path
            let info = AdvertPathInfo(recvTimestamp: contact.lastAdvert, pathLen: 0, pathHashes: [])
            advertPathByContact[key] = info
        } else {
            lastErrorMessage = "No path data available for this contact."
        }
    }

    /// Handle advert path response — associate with the most recently queried contact.
    private func handleAdvertPathResponse(_ info: AdvertPathInfo) {
        pathTimeoutTask?.cancel()
        if let key = pendingAdvertPathKey {
            advertPathByContact[key] = info
            pendingAdvertPathKey = nil
        }
    }

    // MARK: - Allowed Repeat Frequencies

    /// Fetch allowed repeat frequency ranges.
    func requestAllowedRepeatFreq() {
        sendCommand(MeshCoreProtocol.buildGetAllowedRepeatFreq(), label: "GET_ALLOWED_REPEAT_FREQ")
    }

    // MARK: - Pending Contact Management

    /// Accept a pending new contact (from manual_add mode).
    func acceptPendingContact(_ contact: Contact) {
        pendingNewContacts.removeAll { $0.publicKeyPrefix == contact.publicKeyPrefix }
        // The contact is already in the device's table, just add locally
        if !contacts.contains(where: { $0.publicKeyPrefix == contact.publicKeyPrefix }) {
            contacts.append(contact)
        }
    }

    /// Reject a pending new contact (from manual_add mode).
    func rejectPendingContact(_ contact: Contact) {
        pendingNewContacts.removeAll { $0.publicKeyPrefix == contact.publicKeyPrefix }
        // Remove from device
        let frame = MeshCoreProtocol.buildRemoveContact(publicKey: contact.publicKey)
        sendCommand(frame, label: "REJECT_PENDING_CONTACT")
    }

    // MARK: - Channel Sync

    /// Iterate through all channel slots and request info for each.
    /// Called after contact sync completes.
    private var channelSyncTimeoutTask: Task<Void, Never>?

    private func syncChannels() {
        let maxCh = Int(deviceConfig.maxChannels)
        guard maxCh > 0 else { return }
        isSyncingChannels = true
        incomingChannels = []

        // Send CMD_GET_CHANNEL for each slot with small delays to avoid flooding
        for idx in 0..<maxCh {
            let delay = UInt64(idx) * 50_000_000 // 50ms between requests
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: delay)
                let frame = MeshCoreProtocol.buildGetChannel(index: UInt8(idx))
                self.sendCommand(frame, label: "GET_CHANNEL(\(idx))")
            }
        }

        // Timeout: if not all channels received within 10s, complete with what we have
        channelSyncTimeoutTask?.cancel()
        channelSyncTimeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, self.isSyncingChannels else { return }
            DebugLogger.shared.log("Channel sync timeout — completing with \(self.incomingChannels.count) channels", level: .warning)
            self.finalizeChannelSync()
        }
    }

    /// Handle RESP_CODE_CHANNEL_INFO — accumulate channel metadata.
    /// Channel info frames arrive after contacts. Once all maxChannels are received,
    /// we finalize the channel list.
    private func handleChannelInfo(_ channel: MeshChannel) {
        var ch = channel
        // Prefer the secret from the firmware response (now correctly parsed).
        // Fall back to in-memory or Keychain only if firmware didn't provide one.
        if ch.secret == nil {
            if let existing = channels.first(where: { $0.index == channel.index }) {
                ch.secret = existing.secret
            }
        }
        if ch.secret == nil, !ch.name.isEmpty {
            ch.secret = KeychainManager.getChannelSecret(forChannelName: ch.name)
        }
        // Persist the device-provided secret to Keychain for backup
        if let secret = ch.secret, !ch.name.isEmpty {
            _ = KeychainManager.saveChannelSecret(secret, forChannelName: ch.name)
        }
        // Deduplicate by index — replace if already received (handles overlapping syncs)
        if let existingIdx = incomingChannels.firstIndex(where: { $0.index == ch.index }) {
            incomingChannels[existingIdx] = ch
        } else {
            incomingChannels.append(ch)
        }

        // Check if we've received all channels (maxChannels from DeviceInfo)
        let maxCh = deviceConfig.maxChannels
        if maxCh > 0 && incomingChannels.count >= Int(maxCh) {
            finalizeChannelSync()
        }
    }

    /// Finalize channel sync — atomic swap of channel list, keeping only active channels.
    private func finalizeChannelSync() {
        channelSyncTimeoutTask?.cancel()
        let active = incomingChannels.filter { $0.isActive }
        Self.logger.info("Channel sync complete: \(active.count) active channels out of \(self.incomingChannels.count) total")
        channels = active
        incomingChannels = []
        isSyncingChannels = false
    }

    /// Add or update a channel on the device.
    func setChannel(index: UInt8, name: String, secret: Data? = nil) {
        let frame = MeshCoreProtocol.buildSetChannel(index: index, name: name, secret: secret)
        sendCommand(frame, label: "SET_CHANNEL(idx:\(index))")

        // Update locally
        if name.isEmpty {
            // Removal — remove from display and clear stored data
            if let existing = channels.first(where: { $0.index == index }) {
                KeychainManager.deleteChannelSecret(forChannelName: existing.name)
            }
            channels.removeAll { $0.index == index }
            messagesByContact.removeValue(forKey: Data([index]))
            unreadCounts.removeValue(forKey: Data([index]))
        } else {
            // Save secret to iCloud Keychain for cross-device sync
            if let secret, !secret.isEmpty {
                KeychainManager.saveChannelSecret(secret, forChannelName: name)
            }
            // Clear old messages — new secret means old messages are from a different channel
            let channelKey = Data([index])
            if let existing = channels.first(where: { $0.index == index }),
               existing.name != name || existing.secret != secret {
                messagesByContact.removeValue(forKey: channelKey)
                persistMessages(for: channelKey)
                unreadCounts.removeValue(forKey: channelKey)
            }
            let newChannel = MeshChannel(index: index, name: name, flags: secret != nil ? 0x01 : 0x00, secret: secret)
            if let idx = channels.firstIndex(where: { $0.index == index }) {
                channels[idx] = newChannel
            } else {
                channels.append(newChannel)
            }
        }
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
