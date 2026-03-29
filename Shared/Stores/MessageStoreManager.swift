import SwiftUI
import os.log
import UserNotifications
#if os(watchOS)
import WatchKit
#endif
import MeshCoreKit

/// Observable store for messages, ACK tracking, echo detection, drafts, and unread counts.
/// Extracted from MeshCoreViewModel to enable fine-grained view observation.
@MainActor @Observable
final class MessageStoreManager {
    private static let logger = Logger(subsystem: "com.meshcore", category: "MessageStore")

    // MARK: - Public State

    /// All messages keyed by contact public key prefix (6 bytes) or channel key (1 byte).
    var messagesByContact: [Data: [Message]] = [:]

    /// Unread message counts per contact/channel key.
    var unreadCounts: [Data: Int] = [:]

    /// Last exported contact URL (set when exportedContact response arrives).
    var lastExportedURL: String?

    // MARK: - Dependencies (set by coordinator)

    /// Closure to send a command frame to the device.
    var sendCommand: ((Data, String) -> Void)?

    /// Closure to get the display name for a contact key prefix.
    var displayNameProvider: ((Data) -> String)?

    /// Closure to get the current device name (for @mention matching).
    var deviceNameProvider: (() -> String)?

    /// Closure to get the public key hex of the current radio.
    var radioPublicKeyHexProvider: (() -> String)?

    /// Closure to find a contact by key prefix.
    var contactProvider: ((Data) -> Contact?)?

    /// Closure to get channel info by index.
    var channelProvider: ((UInt8) -> MeshChannel?)?

    /// Closure to get channel notification mode.
    var channelNotifyModeProvider: ((String) -> ChannelStore.ChannelNotifyMode)?

    /// Closure to get all channels (for notification context).
    var allChannelsProvider: (() -> [MeshChannel])?

    /// Closure to reset a contact's path (for flood retry).
    var resetPathForContact: ((Contact) -> Void)?

    /// Whether the app is currently in the background.
    var isInBackground = false

    /// Currently selected contact key (to suppress unread count for visible chat).
    var selectedContactKey: Data?

    // MARK: - Private State

    private var persistenceStore = MessageStore()
    private let iCloudStore = NSUbiquitousKeyValueStore.default

    /// The 12-char hex prefix of the connected radio's public key.
    /// Nil when no radio is connected. Used to scope drafts, lastRead, and file storage.
    private(set) var radioPrefix12: String?

    /// Maps expected ACK code -> message tracking info.
    private var pendingACKs: [UInt32: (contactKeyHash: Data, messageID: UUID)] = [:]

    /// Tracks the most recent outgoing channel message for echo detection.
    var pendingChannelEcho: (id: UUID, channelKey: Data, sent: Date)?

    /// Whether we're currently syncing queued messages.
    var isSyncingMessages = false

    // MARK: - Init

    init() {
        // Messages are NOT loaded at init — wait for activateForRadio() after SELF_INFO.
    }

    // MARK: - Per-Radio Activation

    /// Activate message storage for a specific radio. Called after SELF_INFO provides the radio's public key.
    /// Migrates flat files if needed, loads persisted messages, and merges iCloud data.
    func activateForRadio(_ prefix: String) {
        radioPrefix12 = prefix
        persistenceStore = MessageStore(radioPrefix: prefix)
        MessageStore.migrateToPerRadioStorage(radioPrefix: prefix)
        loadPersistedMessages()
        mergeMessagesForCurrentRadio()
    }

    /// Deactivate message storage on disconnect. Clears in-memory messages so the UI shows empty state.
    func deactivate() {
        messagesByContact.removeAll()
        unreadCounts.removeAll()
        radioPrefix12 = nil
        updateAppBadge()
    }

    // MARK: - Message Access

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
        guard let prefix = radioPrefix12 else { return }
        let contactHex = contactKey.map { String(format: "%02x", $0) }.joined()
        let key = "lastRead.\(prefix).\(contactHex)"
        iCloudStore.set(Date().timeIntervalSince1970, forKey: key)
        iCloudStore.synchronize()
    }

    func firstUnreadIndex(in messages: [Message], for contactKey: Data) -> Int? {
        let lastRead = lastReadValue(for: contactKey)
        guard lastRead > 0 else { return nil }
        let lastReadDate = Date(timeIntervalSince1970: lastRead)
        return messages.firstIndex { $0.timestamp > lastReadDate && !$0.isOutgoing }
    }

    func lastReadTimestamp(for contactKey: Data) -> Date? {
        let ts = lastReadValue(for: contactKey)
        guard ts > 0 else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    /// Read lastRead timestamp, trying scoped key first then falling back to legacy.
    private func lastReadValue(for contactKey: Data) -> Double {
        let contactHex = contactKey.map { String(format: "%02x", $0) }.joined()
        if let prefix = radioPrefix12 {
            let scopedKey = "lastRead.\(prefix).\(contactHex)"
            let val = iCloudStore.double(forKey: scopedKey)
            if val > 0 { return val }
        }
        // Fall back to legacy unscoped key
        let legacyKey = "lastRead.\(contactHex)"
        return iCloudStore.double(forKey: legacyKey)
    }

    /// Latest activity date for a contact (for ContactStore activity status).
    func latestActivityDate(for contactKey: Data) -> Date? {
        guard let msgs = messagesByContact[contactKey] else { return nil }
        var latest: Date?
        for msg in msgs {
            if msg.isOutgoing && msg.status == .delivered {
                if latest == nil || msg.timestamp > latest! { latest = msg.timestamp }
            }
            if !msg.isOutgoing {
                if latest == nil || msg.timestamp > latest! { latest = msg.timestamp }
            }
        }
        return latest
    }

    // MARK: - Persistence

    private func loadPersistedMessages() {
        messagesByContact = persistenceStore.loadAllMessages()
    }

    func persistMessages(for contactKeyHash: Data) {
        if let messages = messagesByContact[contactKeyHash] {
            persistenceStore.saveMessages(messages, for: contactKeyHash)
            syncMessagesToiCloud(for: contactKeyHash)
        }
    }

    // MARK: - Drafts

    func saveDraft(_ text: String, for contactKey: Data) {
        guard let prefix = radioPrefix12 else { return }
        let contactHex = contactKey.map { String(format: "%02x", $0) }.joined()
        let key = "draft.\(prefix).\(contactHex)"
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            iCloudStore.removeObject(forKey: key)
        } else {
            iCloudStore.set(text, forKey: key)
        }
        iCloudStore.synchronize()
    }

    func loadDraft(for contactKey: Data) -> String {
        let contactHex = contactKey.map { String(format: "%02x", $0) }.joined()
        if let prefix = radioPrefix12 {
            let scopedKey = "draft.\(prefix).\(contactHex)"
            if let draft = iCloudStore.string(forKey: scopedKey), !draft.isEmpty {
                return draft
            }
        }
        // Fall back to legacy unscoped key
        let legacyKey = "draft.\(contactHex)"
        return iCloudStore.string(forKey: legacyKey) ?? ""
    }

    func hasDraft(for contactKey: Data) -> Bool {
        let contactHex = contactKey.map { String(format: "%02x", $0) }.joined()
        if let prefix = radioPrefix12 {
            let scopedKey = "draft.\(prefix).\(contactHex)"
            if let draft = iCloudStore.string(forKey: scopedKey), !draft.isEmpty {
                return true
            }
        }
        let legacyKey = "draft.\(contactHex)"
        if let draft = iCloudStore.string(forKey: legacyKey), !draft.isEmpty {
            return true
        }
        return false
    }

    func clearAllDrafts() {
        let store = NSUbiquitousKeyValueStore.default
        let keys = store.dictionaryRepresentation.keys.filter { $0.hasPrefix("draft.") }
        for key in keys {
            store.removeObject(forKey: key)
        }
        store.synchronize()
    }

    // MARK: - Send Messages

    func sendTextMessage(_ text: String, to contact: Contact) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

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
        sendCommand?(frame, "SEND_TXT")
    }

    func sendChannelMessage(_ text: String, channelIndex: UInt8 = 0) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let frame = MeshCoreProtocol.buildSendChannelMessage(
            text: trimmed,
            channelIndex: channelIndex
        )
        Self.logger.info("CHANNEL TX: [\(frame.count) bytes] \(frame.map { String(format: "%02X", $0) }.joined(separator: " "))")
        let frameHex = frame.map { String(format: "%02X", $0) }.joined(separator: " ")
        DebugLogger.shared.log("CH TX: ch=\(frame[2]) [\(frame.count)B] \(frameHex)", level: .tx)
        DebugLogger.shared.log("CH TX: text='\(trimmed)'", level: .tx)
        sendCommand?(frame, "SEND_CHANNEL_TXT")

        let channelKey = Data([channelIndex])
        let outgoing = Message(
            contactKeyHash: channelKey,
            text: trimmed,
            timestamp: Date(),
            isOutgoing: true,
            status: .sent,
            channelIndex: channelIndex
        )
        messagesByContact[channelKey, default: []].append(outgoing)
        persistMessages(for: channelKey)

        pendingChannelEcho = (id: outgoing.id, channelKey: channelKey, sent: Date())
        DebugLogger.shared.log("ECHO: armed pending echo for ch=\(channelIndex)", level: .info)
    }

    func sendRoomMessage(_ text: String, to contact: Contact) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let frame = MeshCoreProtocol.buildSendTextMessage(
            text: trimmed,
            recipientKeyHash: contact.publicKeyPrefix,
            txtType: 0
        )
        sendCommand?(frame, "SEND_ROOM_TXT")

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

    func syncNextMessage() {
        isSyncingMessages = true
        sendCommand?(MeshCoreProtocol.buildSyncNextMessage(), "SYNC_NEXT_MSG")
    }

    // MARK: - ACK Handling

    func handleSentResponse(expectedACK: UInt32, suggestedTimeoutMs: UInt32) {
        var matched = false
        for (contactKey, messages) in messagesByContact {
            if let idx = messages.lastIndex(where: { $0.isOutgoing && ($0.status == .sending || $0.status == .retrying || $0.status == .flooding) }) {
                Self.logger.info("DM RESP_SENT: matched message \(messages[idx].id) → .sent, ack=\(expectedACK)")
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

    func handleSendConfirmed(ackCode: UInt32, roundTripMs: UInt32) {
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

    private func handleACKTimeout(ackCode: UInt32) {
        guard let pending = pendingACKs.removeValue(forKey: ackCode) else { return }

        guard var messages = messagesByContact[pending.contactKeyHash],
              let idx = messages.firstIndex(where: { $0.id == pending.messageID }),
              messages[idx].status == .sent else { return }

        let message = messages[idx]
        let autoRetry = UserDefaults.standard.bool(forKey: "autoRetry")
        let autoResetPath = UserDefaults.standard.bool(forKey: "autoResetPath")
        let maxDirectRetries: UInt8 = 1
        let maxFloodRetries: UInt8 = 2

        // Phase 1: Direct path retries
        if !message.didResetPath && message.attempt < maxDirectRetries - 1 {
            if autoRetry {
                Self.logger.info("ACK timeout for message \(pending.messageID), auto-retrying (attempt \(message.attempt + 1))")
                messages[idx].status = .retrying
                messages[idx].attempt += 1
                let attempt = messages[idx].attempt
                let contactKey = pending.contactKeyHash
                messagesByContact[contactKey] = messages
                persistMessages(for: contactKey)

                if let channelIdx = message.channelIndex {
                    let frame = MeshCoreProtocol.buildSendChannelMessage(text: message.text, channelIndex: channelIdx)
                    sendCommand?(frame, "AUTO_RETRY_CHANNEL(\(attempt))")
                } else {
                    let frame = MeshCoreProtocol.buildSendTextMessage(text: message.text, recipientKeyHash: contactKey, attempt: attempt)
                    sendCommand?(frame, "AUTO_RETRY_TXT(\(attempt))")
                }
                return
            }
        }

        // Phase 2: Reset path and flood
        if autoRetry && autoResetPath && !message.didResetPath && message.channelIndex == nil {
            Self.logger.info("Direct retries exhausted for \(pending.messageID), resetting path and flooding")
            messages[idx].status = .flooding
            messages[idx].didResetPath = true
            messages[idx].attempt = 0
            let contactKey = pending.contactKeyHash
            messagesByContact[contactKey] = messages
            persistMessages(for: contactKey)

            if let contact = contactProvider?(contactKey) {
                resetPathForContact?(contact)
            }

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                let frame = MeshCoreProtocol.buildSendTextMessage(text: message.text, recipientKeyHash: contactKey, attempt: 0)
                self.sendCommand?(frame, "FLOOD_RETRY_TXT")
            }
            return
        }

        // Phase 3: Flood retries
        if message.didResetPath && message.attempt < maxFloodRetries - 1 {
            if autoRetry {
                Self.logger.info("Flood retry for \(pending.messageID) (attempt \(message.attempt + 1))")
                messages[idx].status = .flooding
                messages[idx].attempt += 1
                let attempt = messages[idx].attempt
                let contactKey = pending.contactKeyHash
                messagesByContact[contactKey] = messages
                persistMessages(for: contactKey)

                let frame = MeshCoreProtocol.buildSendTextMessage(text: message.text, recipientKeyHash: contactKey, attempt: attempt)
                sendCommand?(frame, "FLOOD_RETRY_TXT(\(attempt))")
                return
            }
        }

        // All retries exhausted
        Self.logger.info("All retries exhausted for message \(pending.messageID), marking as failed")
        messages[idx].status = .failed
        messagesByContact[pending.contactKeyHash] = messages
        persistMessages(for: pending.contactKeyHash)
    }

    // MARK: - Incoming Messages

    /// Handle an incoming message. Returns the message if stored (for notification).
    func handleIncomingMessage(_ message: Message) -> Message? {
        let contactKey = message.contactKeyHash

        let existing = messagesByContact[contactKey] ?? []
        let isDuplicate = existing.contains { msg in
            msg.text == message.text &&
            abs(msg.timestamp.timeIntervalSince(message.timestamp)) < 2 &&
            msg.isOutgoing == message.isOutgoing
        }
        guard !isDuplicate else {
            Self.logger.debug("Skipping duplicate message")
            return nil
        }

        messagesByContact[contactKey, default: []].append(message)
        persistMessages(for: contactKey)

        if !isInBackground {
            playReceiveHaptic()
        }

        if selectedContactKey != contactKey {
            unreadCounts[contactKey, default: 0] += 1
            updateAppBadge()
        }

        return message
    }

    // MARK: - Echo Detection (0x88)

    func handleLogRxData(_ payload: Data) {
        let snr = payload.count > 0 ? Int8(bitPattern: payload[0]) : 0

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
                pendingChannelEcho = nil
            }
        }
    }

    // MARK: - Delete / Clear

    func deleteMessage(_ message: Message, in contactKey: Data) {
        if var messages = messagesByContact[contactKey],
           let idx = messages.firstIndex(where: { $0.id == message.id }) {
            messages.remove(at: idx)
            messagesByContact[contactKey] = messages
            persistMessages(for: contactKey)
        }
    }

    func clearAllMessages() {
        messagesByContact.removeAll()
        persistenceStore.deleteAllMessages()
        unreadCounts.removeAll()
        updateAppBadge()
    }

    func retryMessage(_ message: Message) {
        guard message.isOutgoing, message.status == .failed else { return }
        let contactKey = message.contactKeyHash

        if var messages = messagesByContact[contactKey],
           let idx = messages.firstIndex(where: { $0.id == message.id }) {

            if message.channelIndex == nil {
                if let contact = contactProvider?(contactKey) {
                    Self.logger.info("RETRY: resetting path for \(contact.name) before flood retry")
                    resetPathForContact?(contact)
                }
                messages[idx].status = .sending
                messages[idx].attempt = 2
                messages[idx].didResetPath = true
                messagesByContact[contactKey] = messages

                let msgID = message.id
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard let self else { return }
                    Self.logger.info("RETRY: sending flood for \(msgID) with attempt=2")
                    let frame = MeshCoreProtocol.buildSendTextMessage(text: message.text, recipientKeyHash: contactKey, attempt: 2)
                    self.sendCommand?(frame, "MANUAL_RETRY_FLOOD")
                }
            } else {
                messages[idx].status = .sending
                messages[idx].attempt = 0
                messagesByContact[contactKey] = messages
                let frame = MeshCoreProtocol.buildSendChannelMessage(text: message.text, channelIndex: message.channelIndex!)
                sendCommand?(frame, "MANUAL_RETRY_CHANNEL")
            }
            persistMessages(for: contactKey)
        }
    }

    // MARK: - Mark All Sending as Failed (disconnect)

    func markAllSendingAsFailed() {
        for (contactKey, messages) in messagesByContact {
            var updated = messages
            var changed = false
            for i in updated.indices where updated[i].isOutgoing && updated[i].status == .sending {
                updated[i].status = .failed
                changed = true
            }
            if changed {
                messagesByContact[contactKey] = updated
                persistMessages(for: contactKey)
            }
        }
        pendingACKs.removeAll()
    }

    // MARK: - iCloud Message Sync

    func syncMessagesToiCloud(for contactKeyHash: Data) {
        guard UserDefaults.standard.object(forKey: "iCloudSyncEnabled") == nil
                || UserDefaults.standard.bool(forKey: "iCloudSyncEnabled") else { return }
        let radioKey = radioPublicKeyHexProvider?() ?? ""
        guard !radioKey.isEmpty else { return }

        let contactHex = contactKeyHash.map { String(format: "%02x", $0) }.joined()
        let key = "msg.\(radioKey.prefix(12)).\(contactHex)"

        guard let messages = messagesByContact[contactKeyHash] else { return }
        let recent = Array(messages.suffix(50))

        if let data = try? JSONEncoder().encode(recent), data.count < 60_000 {
            iCloudStore.set(data, forKey: key)
        }
    }

    func mergeMessagesForCurrentRadio() {
        let radioKey = radioPublicKeyHexProvider?() ?? ""
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
                persistenceStore.saveMessages(merged, for: contactKeyHash)
            }
        }

        if mergedCount > 0 {
            Self.logger.info("iCloud sync: merged \(mergedCount) messages from other devices")
        }
    }

    // MARK: - Notifications

    func postLocalNotification(for message: Message) {
        guard isInBackground else { return }

        let prefs = NotificationPreferences.shared
        let isChannel = message.channelIndex != nil
        let contact = contactProvider?(message.contactKeyHash)
        let isRoom = contact?.type == .room

        if isChannel {
            guard prefs.notifyChannel else { return }
            if let chIdx = message.channelIndex,
               let channel = channelProvider?(chIdx) {
                let mode = channelNotifyModeProvider?(channel.name) ?? .all
                if mode == .muted { return }
                if mode == .mentionsOnly {
                    let myName = (deviceNameProvider?() ?? "").lowercased()
                    guard !myName.isEmpty, message.text.lowercased().contains("@\(myName)") else { return }
                }
            }
        } else if isRoom {
            guard prefs.notifyRoom else { return }
        } else {
            // Suppress notifications from infrastructure nodes (repeaters, sensors)
            if let contact, contact.type == .repeater || contact.type == .sensor {
                return
            }
            guard prefs.notifyDirect else { return }
        }

        let content = UNMutableNotificationContent()
        content.sound = .default

        let senderName = message.senderName
            ?? contact.map { displayNameProvider?($0.publicKeyPrefix) ?? $0.name }

        if let channelIdx = message.channelIndex {
            let channels = allChannelsProvider?() ?? []
            let channelName = channels.first(where: { $0.index == channelIdx })?.name ?? "Channel"
            content.title = channelName
            if let name = message.senderName, !name.isEmpty {
                content.subtitle = name
            }
            content.threadIdentifier = "channel.\(channelIdx)"
        } else if let name = senderName {
            content.title = name
            content.threadIdentifier = "dm.\(message.contactKeyHash.map { String(format: "%02x", $0) }.joined())"
        } else {
            content.title = "New Message"
        }
        content.body = message.text

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

        let totalUnread = unreadCounts.values.reduce(0, +)
        content.badge = NSNumber(value: totalUnread)

        DebugLogger.shared.log("NOTIF: posting notification for '\(message.text.prefix(30))'", level: .info)
        let request = UNNotificationRequest(
            identifier: message.id.uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Badge

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

    // MARK: - Haptics

    func playHapticFeedback() {
        #if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        #elseif os(watchOS)
        WKInterfaceDevice.current().play(.click)
        #endif
    }

    func playReceiveHaptic() {
        #if os(iOS)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        #elseif os(watchOS)
        WKInterfaceDevice.current().play(.notification)
        #endif
    }

    // MARK: - Reset

    func reset() {
        isSyncingMessages = false
        pendingACKs.removeAll()
        pendingChannelEcho = nil
    }
}
