import SwiftUI
import Combine
import os.log
import UserNotifications
#if os(watchOS)
import WatchKit
#endif
import MeshCoreKit

@MainActor
final class MeshCoreViewModel: ObservableObject {
    private static let logger = Logger(subsystem: "com.meshcore", category: "ViewModel")

    @Published var contacts: [Contact] = []
    @Published var selectedContact: Contact?
    @Published var showPublicChannel = false
    @Published var selectedChannelIndex: UInt8? = nil
    @Published var isScanning = false
    @Published var discoveredPeripherals: [DiscoveredPeripheral] = []
    @Published var connectionState: BLEConnectionState = .disconnected
    @Published var connectedDeviceName: String?
    @Published var deviceConfig = DeviceConfig()

    /// All messages keyed by contact public key prefix (6 bytes).
    @Published var messagesByContact: [Data: [Message]] = [:]

    /// Unread message counts per contact key prefix.
    @Published var unreadCounts: [Data: Int] = [:]

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

    let bleManager = BLEManager()
    private var cancellables = Set<AnyCancellable>()
    private let messageStore = MessageStore()

    /// Maps expected ACK code → message ID for delivery tracking.
    private var pendingACKs: [UInt32: (contactKeyHash: Data, messageID: UUID)] = [:]

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
    }

    private func persistMessages(for contactKeyHash: Data) {
        if let messages = messagesByContact[contactKeyHash] {
            messageStore.saveMessages(messages, for: contactKeyHash)
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
    }

    /// Post a local notification for an incoming message when the app is backgrounded.
    private func postLocalNotification(for message: Message) {
        guard isInBackground else { return }

        let content = UNMutableNotificationContent()
        content.sound = .default

        // Find contact name for the notification title
        let senderName = message.senderName
            ?? contacts.first(where: { $0.publicKeyPrefix == message.contactKeyHash })?.name

        if let channelIdx = message.channelIndex {
            content.title = "Public Channel"
            if let name = message.senderName, !name.isEmpty {
                content.subtitle = name
            }
            _ = channelIdx // suppress unused warning
        } else if let name = senderName {
            content.title = name
        } else {
            content.title = "New Message"
        }
        content.body = message.text

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

    /// Trigger haptic feedback on message send.
    func playHapticFeedback() {
        #if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        #elseif os(watchOS)
        WKInterfaceDevice.current().play(.click)
        #endif
    }

    private func setupSubscriptions() {
        bleManager.receivedDataSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data in
                self?.handleReceivedData(data)
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
                    // Show error if disconnected while operations were in progress
                    let wasActive = previousState == .ready || previousState == .connected
                    if wasActive {
                        self.lastErrorMessage = "Device disconnected. Reconnect to continue."
                    }
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
                }
                if state == .ready && previousState != .ready {
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
    }

    private func onDeviceReady() {
        refreshAllSettings()
        requestContacts(fullSync: true)
        isSyncingChannels = true
        incomingChannels = []
        syncNextMessage()
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

    func disconnect() {
        bleManager.disconnect()
    }

    // MARK: - Protocol Commands

    private func sendCommand(_ data: Data, label: String) {
        guard connectionState == .ready || connectionState == .connected else {
            Self.logger.warning("Cannot send \(label) — not connected (state: \(String(describing: self.connectionState)))")
            return
        }
        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        Self.logger.info("TX \(label) [\(data.count) bytes]: \(hex)")
        bleManager.send(data: data)
    }

    func sendAppStart() {
        sendCommand(MeshCoreProtocol.buildAppStart(), label: "APP_START")
    }

    func requestDeviceInfo() {
        sendCommand(MeshCoreProtocol.buildDeviceQuery(), label: "DEVICE_QUERY")
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
    }

    // MARK: - Settings Commands

    func setAdvertName(_ name: String) {
        sendCommand(MeshCoreProtocol.buildSetAdvertName(name), label: "SET_ADVERT_NAME")
    }

    func setAdvertLatLon(latitude: Double, longitude: Double) {
        sendCommand(MeshCoreProtocol.buildSetAdvertLatLon(latitude: latitude, longitude: longitude), label: "SET_LATLON")
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
        sendCommand(MeshCoreProtocol.buildSetTuningParams(rxDelayBase: rxDelayBase, airtimeFactor: airtimeFactor), label: "SET_TUNING")
    }

    func setOtherParams(manualAddContacts: UInt8, telemetryBase: UInt8, telemetryLocation: UInt8, advertLocPolicy: UInt8, multiACK: UInt8) {
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
        if selectedContact?.publicKeyPrefix == contact.publicKeyPrefix {
            selectedContact = nil
        }
    }

    /// Reset the outbound path for a contact. Sends CMD_RESET_PATH.
    func resetPath(for contact: Contact) {
        let frame = MeshCoreProtocol.buildResetPath(publicKey: contact.publicKey)
        sendCommand(frame, label: "RESET_PATH")
    }

    /// Share a contact's advert on the mesh (zero-hop). Sends CMD_SHARE_CONTACT.
    func shareContact(_ contact: Contact) {
        let frame = MeshCoreProtocol.buildShareContact(publicKey: contact.publicKey)
        sendCommand(frame, label: "SHARE_CONTACT")
    }

    /// Export a contact as a meshcore:// URL. Result arrives as .exportedContact response.
    func exportContact(_ contact: Contact) {
        let frame = MeshCoreProtocol.buildExportContact(publicKey: contact.publicKey)
        sendCommand(frame, label: "EXPORT_CONTACT")
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

    // MARK: - Messaging

    func messages(for contact: Contact) -> [Message] {
        messagesByContact[contact.publicKeyPrefix] ?? []
    }

    func unreadCount(for contact: Contact) -> Int {
        unreadCounts[contact.publicKeyPrefix] ?? 0
    }

    func markAsRead(_ contact: Contact) {
        unreadCounts[contact.publicKeyPrefix] = 0
    }

    func sendTextMessage(_ text: String, to contact: Contact) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let frame = MeshCoreProtocol.buildSendTextMessage(
            text: trimmed,
            recipientKeyHash: contact.publicKeyPrefix
        )
        sendCommand(frame, label: "SEND_TXT")

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

    func sendChannelMessage(_ text: String, channelIndex: UInt8 = 0) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let frame = MeshCoreProtocol.buildSendChannelMessage(
            text: trimmed,
            channelIndex: channelIndex
        )
        sendCommand(frame, label: "SEND_CHANNEL_TXT")

        let channelKey = Data([channelIndex])
        let outgoing = Message(
            contactKeyHash: channelKey,
            text: trimmed,
            timestamp: Date(),
            isOutgoing: true,
            status: .sending,
            channelIndex: channelIndex
        )
        messagesByContact[channelKey, default: []].append(outgoing)
        persistMessages(for: channelKey)
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
    func loginToRemoteDevice(_ contact: Contact, password: String) {
        let session = remoteSession(for: contact)
        // Guard against double-sends if already logging in
        if case .loggingIn = session.loginState { return }
        session.loginState = .loggingIn
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
    /// Called when the management screen opens (not on login).
    func fetchRemoteSettings(for contact: Contact) {
        let session = remoteSession(for: contact)
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
            "powersaving", "gps",
        ]

        session.fetchTotalCount = commands.count

        Task { [weak self] in
            for command in commands {
                guard let self else { return }
                await self.fetchRemoteSetting(command: command, contact: contact, session: session)
            }
            session.isFetchingSettings = false
            session.hasLoadedFullSettings = true
        }
    }

    /// Send a single CLI command during settings fetch, poll for response, wait for it.
    private func fetchRemoteSetting(command: String, contact: Contact, session: RemoteDeviceSession) async {
        let cmdIndex = session.commandSent(command)

        let frame = MeshCoreProtocol.buildSendCLICommand(
            command: command,
            recipientKeyHash: contact.publicKeyPrefix
        )
        sendCommand(frame, label: "CLI_FETCH")

        // Wait for radio transmission, then poll
        try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
        syncNextMessage()

        // Wait up to 3 seconds for the response to arrive
        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if cmdIndex < session.cliHistory.count && session.cliHistory[cmdIndex].isComplete {
                return
            }
        }

        // Timeout
        session.timeoutCommand(at: cmdIndex)
    }

    // MARK: - Response Handling

    private func handleReceivedData(_ data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        Self.logger.info("RX [\(data.count)]: \(hex)")

        let response = FrameParser.parse(data)

        switch response {
        case .ok:
            Self.logger.debug("OK response")

        case .error(let code, let description):
            Self.logger.warning("Error response: code=\(code) \(description)")
            handleErrorResponse(code: code, description: description)

        case .selfInfo(let info):
            Self.logger.info("PARSED SelfInfo: name='\(info.name)' txPwr=\(info.txPower)/\(info.maxTXPower) freq=\(info.radioFreq) bw=\(info.radioBW) sf=\(info.radioSF) cr=\(info.radioCR) lat=\(info.latitude) lon=\(info.longitude)")
            deviceConfig.deviceName = info.name
            deviceConfig.radioTXPower = info.txPower
            deviceConfig.maxTXPower = info.maxTXPower
            deviceConfig.publicKeyHex = info.publicKey.map { String(format: "%02x", $0) }.joined()
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
            deviceConfig.loadedSections.insert("battAndStorage")
            checkLoadingComplete()

        case .currentTime(let epoch):
            Self.logger.info("PARSED Time: epoch=\(epoch)")
            deviceConfig.deviceTimeEpoch = epoch
            deviceConfig.loadedSections.insert("time")
            checkLoadingComplete()

        case .tuningParams(let rxDelay, let airtime):
            Self.logger.info("PARSED Tuning: rxDelay=\(rxDelay) airtime=\(airtime)")
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

        case .contactsStart(let count):
            Self.logger.info("Contacts sync starting: \(count) contacts expected")
            expectedContactCount = count
            // Clear only the buffer, never the displayed contacts
            incomingContacts = []

        case .contact(let contact):
            Self.logger.info("Received contact: \(contact.name) type=\(contact.type.rawValue)")
            incomingContacts.append(contact)

        case .endOfContacts(let lastmod):
            Self.logger.info("Contacts sync complete: \(self.incomingContacts.count) contacts, lastmod=\(lastmod), incremental=\(self.isIncrementalContactSync)")
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

            // Sync channels after contacts complete
            syncChannels()

        case .sent(let type, let expectedACK, let suggestedTimeout):
            Self.logger.info("PARSED Sent: type=\(type) expectedACK=\(expectedACK) timeout=\(suggestedTimeout)ms")
            handleSentResponse(expectedACK: expectedACK, suggestedTimeoutMs: suggestedTimeout)

        case .contactMsgRecv(let message):
            Self.logger.info("Received direct message: \(message.text)")
            handleIncomingMessage(message)
            if isSyncingMessages {
                syncNextMessage()
            }

        case .channelMsgRecv(let message):
            Self.logger.info("Channel message: ch=\(message.channelIndex ?? 0) text=\(message.text)")
            handleIncomingMessage(message)
            if isSyncingMessages {
                syncNextMessage()
            }

        case .noMoreMessages:
            Self.logger.debug("No more messages")
            isSyncingMessages = false

        case .sendConfirmed(let ackCode, let roundTripMs):
            Self.logger.info("PARSED SendConfirmed: ackCode=\(ackCode) roundTrip=\(roundTripMs)ms")
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
            Self.logger.info("PUSH Advert from: \(contact.name)")
            handleAdvert(contact)

        case .pathUpdated(let publicKey):
            Self.logger.info("PUSH PathUpdated: key=\(publicKey.prefix(6).map { String(format: "%02x", $0) }.joined())")
            // Trigger incremental contact sync to pick up the new path
            requestContacts()

        case .newAdvert(let contact):
            Self.logger.info("PUSH NewAdvert (manual_add): \(contact.name)")
            // Add to pending contacts list for user approval
            if !pendingNewContacts.contains(where: { $0.publicKeyPrefix == contact.publicKeyPrefix }) {
                pendingNewContacts.append(contact)
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
            lastTraceResult = result

        case .telemetryResponse(let senderKey, let readings):
            Self.logger.info("PUSH Telemetry: \(readings.count) readings from \(senderKey.prefix(6).map { String(format: "%02x", $0) }.joined())")
            telemetryByContact[senderKey] = readings
            if pendingTelemetryKey == senderKey { pendingTelemetryKey = nil }

        case .controlData(let snr, let rssi, let pathLen, let payload):
            Self.logger.info("PUSH ControlData: snr=\(snr) rssi=\(rssi) pathLen=\(pathLen)")
            handleControlData(snr: snr, rssi: rssi, pathLen: pathLen, payload: payload)

        case .channelInfo(let channel):
            Self.logger.info("Channel info: idx=\(channel.index) name='\(channel.name)' flags=\(channel.flags)")
            handleChannelInfo(channel)

        case .exportedContact(let url):
            Self.logger.info("Exported contact URL: \(url)")
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

        case .rawMeshPacket(let pktData):
            Self.logger.debug("Raw mesh packet: \(pktData.count) bytes")

        case .contactDeleted(let publicKey):
            let keyPrefix = publicKey.prefix(6)
            let name = contacts.first(where: { $0.publicKeyPrefix == keyPrefix })?.name ?? "Unknown"
            Self.logger.info("Contact deleted by device: \(name)")
            contacts.removeAll { $0.publicKeyPrefix == keyPrefix }
            lastErrorMessage = "Contact \"\(name)\" was removed from device to make room for new contacts."

        case .contactsFull(let maxContacts):
            Self.logger.warning("Contact storage full: \(maxContacts)")
            lastErrorMessage = "Contact storage is full (\(maxContacts) contacts). New contacts cannot be added."

        case .unknown(let type, let payload):
            // Push notifications are informational — log at debug level
            if type >= 0x80 {
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
            loginTimeoutTask = Task { [weak self] in
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

        for (contactKey, messages) in messagesByContact {
            if let idx = messages.lastIndex(where: { $0.isOutgoing && $0.status == .sending }) {
                messagesByContact[contactKey]![idx].status = .sent
                messagesByContact[contactKey]![idx].expectedACK = expectedACK
                pendingACKs[expectedACK] = (contactKeyHash: contactKey, messageID: messages[idx].id)
                persistMessages(for: contactKey)

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
    }

    /// Handle PUSH_CODE_SEND_CONFIRMED — recipient ACKed our message.
    private func handleSendConfirmed(ackCode: UInt32, roundTripMs: UInt32) {
        guard let pending = pendingACKs.removeValue(forKey: ackCode) else {
            Self.logger.warning("Received ACK for unknown code: \(ackCode)")
            return
        }

        if var messages = messagesByContact[pending.contactKeyHash],
           let idx = messages.firstIndex(where: { $0.id == pending.messageID }) {
            messages[idx].status = .delivered
            messages[idx].roundTripMs = roundTripMs
            messagesByContact[pending.contactKeyHash] = messages
            persistMessages(for: pending.contactKeyHash)
        }
    }

    /// Handle ACK timeout — mark as .failed so user can retry.
    private func handleACKTimeout(ackCode: UInt32) {
        guard let pending = pendingACKs.removeValue(forKey: ackCode) else { return }

        if var messages = messagesByContact[pending.contactKeyHash],
           let idx = messages.firstIndex(where: { $0.id == pending.messageID }),
           messages[idx].status == .sent {
            Self.logger.info("ACK timeout for message \(pending.messageID), marking as failed")
            messages[idx].status = .failed
            messagesByContact[pending.contactKeyHash] = messages
            persistMessages(for: pending.contactKeyHash)
        }
    }

    /// Retry sending a failed message. Increments attempt count (max 3).
    func retryMessage(_ message: Message) {
        guard message.isOutgoing, message.status == .failed, message.attempt < 3 else { return }
        let contactKey = message.contactKeyHash

        // Update existing message to sending with incremented attempt
        if var messages = messagesByContact[contactKey],
           let idx = messages.firstIndex(where: { $0.id == message.id }) {
            messages[idx].status = .sending
            messages[idx].attempt += 1
            let attempt = messages[idx].attempt
            messagesByContact[contactKey] = messages

            // Re-send the frame with incremented attempt
            if let channelIdx = message.channelIndex {
                let frame = MeshCoreProtocol.buildSendChannelMessage(
                    text: message.text,
                    channelIndex: channelIdx
                )
                sendCommand(frame, label: "RETRY_CHANNEL_TXT(\(attempt))")
            } else {
                let frame = MeshCoreProtocol.buildSendTextMessage(
                    text: message.text,
                    recipientKeyHash: contactKey,
                    attempt: attempt
                )
                sendCommand(frame, label: "RETRY_TXT(\(attempt))")
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
                // Sync stored messages first (room server pushes last 32 messages)
                syncNextMessage()
                if let contact = contacts.first(where: { $0.publicKeyPrefix == key }) {
                    // Only fetch basic info (ver + clock) on login — full settings deferred to management screen
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s
                        self?.fetchBasicRemoteInfo(for: contact)
                    }
                }
                return
            }
        }
    }

    /// Fetch only ver + clock from a remote device (fast, called on login).
    func fetchBasicRemoteInfo(for contact: Contact) {
        let session = remoteSession(for: contact)
        let commands = ["ver", "clock"]
        session.isFetchingSettings = true
        session.fetchTotalCount = commands.count
        session.fetchReceivedCount = 0

        Task { [weak self] in
            for command in commands {
                guard let self else { return }
                await self.fetchRemoteSetting(command: command, contact: contact, session: session)
            }
            session.isFetchingSettings = false
        }
    }

    /// Handle login failure.
    private func handleLoginFail() {
        loginTimeoutTask?.cancel()
        loginTimeoutTask = nil
        for (_, session) in remoteSessions {
            if case .loggingIn = session.loginState {
                session.loginState = .loginFailed(message: "Login failed \u{2014} incorrect password.")
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

        if selectedContact?.publicKeyPrefix != contactKey {
            unreadCounts[contactKey, default: 0] += 1
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
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, self.isDiscovering else { return }
                self.isDiscovering = false
            }
        }
    }

    /// Fallback discover: send flood advertisement and listen for advert responses.
    private func startDiscoverFallback() {
        discoverFallbackMessage = "Using advertisement-based discovery (firmware does not support active discover scan)"
        sendCommand(MeshCoreProtocol.buildSendSelfAdvert(advertType: 1), label: "FLOOD_ADVERT_DISCOVER")

        // Listen for 30 seconds
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self, self.isDiscovering else { return }
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
        lastTraceResult = nil
        let frame = MeshCoreProtocol.buildSendTracePath(outPath: contact.outPath, tag: tag)
        sendCommand(frame, label: "TRACE_PATH")

        // Timeout after 15 seconds
        let timeout: UInt64 = 15_000_000_000
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: timeout)
            guard let self, self.pendingTraceTag == tag else { return }
            self.pendingTraceTag = nil
            if self.lastTraceResult == nil {
                self.lastErrorMessage = "Trace route timed out — the path may not be reachable."
            }
        }
    }

    // MARK: - Status & Telemetry

    /// Request status from a remote device (repeater/sensor).
    func requestStatus(for contact: Contact) {
        pendingStatusKey = contact.publicKeyPrefix
        let frame = MeshCoreProtocol.buildSendStatusReq(recipientPublicKey: contact.publicKey)
        sendCommand(frame, label: "STATUS_REQ")
    }

    /// Request telemetry from a sensor contact.
    func requestTelemetry(for contact: Contact) {
        let key = contact.publicKeyPrefix
        pendingTelemetryKey = key
        let frame = MeshCoreProtocol.buildSendTelemetryReq(recipientPublicKey: contact.publicKey)
        sendCommand(frame, label: "TELEMETRY_REQ")

        // Timeout after 15 seconds
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, self.pendingTelemetryKey == key else { return }
            self.pendingTelemetryKey = nil
            if self.telemetryByContact[key] == nil {
                self.lastErrorMessage = "No telemetry response — the node may not support telemetry or is out of range."
            }
        }
    }

    /// Handle status response — associate with the most recently requested contact.
    private func handleStatusResponse(_ info: RemoteStatusInfo) {
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

        // Timeout after 10 seconds — fall back to stored path info
        let key = contact.publicKeyPrefix
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, self.pendingAdvertPathKey == key else { return }
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
    }

    /// Handle RESP_CODE_CHANNEL_INFO — accumulate channel metadata.
    /// Channel info frames arrive after contacts. Once all maxChannels are received,
    /// we finalize the channel list.
    private func handleChannelInfo(_ channel: MeshChannel) {
        // Preserve locally-stored secrets
        var ch = channel
        if let existing = channels.first(where: { $0.index == channel.index }) {
            ch.secret = existing.secret
        }
        incomingChannels.append(ch)

        // Check if we've received all channels (maxChannels from DeviceInfo)
        let maxCh = deviceConfig.maxChannels
        if maxCh > 0 && incomingChannels.count >= Int(maxCh) {
            finalizeChannelSync()
        }
    }

    /// Finalize channel sync — atomic swap of channel list, keeping only active channels.
    private func finalizeChannelSync() {
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
        let newChannel = MeshChannel(index: index, name: name, flags: secret != nil ? 0x01 : 0x00, secret: secret)
        if let idx = channels.firstIndex(where: { $0.index == index }) {
            channels[idx] = newChannel
        } else {
            channels.append(newChannel)
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
