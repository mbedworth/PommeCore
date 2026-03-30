import SwiftUI
import os.log
#if canImport(CoreSpotlight)
import CoreSpotlight
import UniformTypeIdentifiers
#endif
import MeshCoreKit

/// Observable store for contacts, nicknames, notes, groups, and activity status.
/// Extracted from MeshCoreViewModel to enable fine-grained view observation.
@MainActor @Observable
final class ContactStore {
    private static let logger = Logger(subsystem: "com.meshcore", category: "ContactStore")

    // MARK: - Public State

    var contacts: [Contact] = []
    var pendingNewContacts: [Contact] = []
    var contactGroups: [ContactGroup] = []

    // MARK: - Dependencies (set by coordinator)

    /// Closure to send a command frame to the device.
    var sendCommand: ((Data, String) -> Void)?

    /// Closure to get latest activity date for a contact (checks messages).
    var activityDateProvider: ((Data) -> Date?)?

    /// Closure to clear messages when a contact is deleted.
    var clearMessagesForContact: ((Data) -> Void)?

    /// Closure to post an event notification.
    var postEventNotification: ((String, String, String) -> Void)?

    /// Closure to get the connected radio's public key hex (for per-radio data isolation).
    var radioPublicKeyHexProvider: (() -> String)?

    // MARK: - Private State

    private let iCloudStore = NSUbiquitousKeyValueStore.default
    private var nicknames: [String: String] = [:]
    private var contactNotes: [String: String] = [:]

    // Contact sync state
    var incomingContacts: [Contact] = []
    var isSyncingContacts = false
    var isIncrementalContactSync = false
    var lastContactsSync: UInt32 = 0
    var expectedContactCount: UInt32 = 0
    private var contactSyncDebounceTask: Task<Void, Never>?

    // MARK: - Init

    init() {
        // Don't load nicknames/notes at init — radio pubkey isn't known yet.
        // They are loaded in handleSelfInfo when the radio connects.
        loadContactGroupsFromiCloud()
        observeiCloudChanges()
    }

    // MARK: - Sorted Contacts

    var sortedContacts: [Contact] {
        contacts.sorted { a, b in
            if a.isFavourite != b.isFavourite {
                return a.isFavourite
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    // MARK: - Nicknames

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
        guard let value = nicknames[key], !value.isEmpty else { return nil }
        return value
    }

    func displayName(for contact: Contact) -> String {
        if let nick = nickname(for: contact), !nick.isEmpty { return nick }
        if !contact.name.isEmpty { return contact.name }
        // Fallback for contacts with no name (e.g. factory-reset or new radios)
        return contact.publicKey.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Resolve a channel message sender name to a nickname if one exists.
    func channelSenderDisplayName(_ rawSenderName: String) -> String {
        if let contact = contacts.first(where: { $0.name == rawSenderName }) {
            return displayName(for: contact)
        }
        return rawSenderName
    }

    /// iCloud key for nicknames, scoped to the connected radio.
    private var nicknamesKey: String {
        let radioKey = radioPublicKeyHexProvider?() ?? ""
        return radioKey.isEmpty ? "contactNicknames" : "nicknames.\(String(radioKey.prefix(12)))"
    }

    func loadNicknamesFromiCloud() {
        if let data = iCloudStore.data(forKey: nicknamesKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            nicknames = decoded
                .filter { !$0.value.isEmpty }
                .mapValues { $0.count > 32 ? String($0.prefix(32)) : $0 }
            return
        }

        nicknames = [:]
    }

    private func saveNicknamesToiCloud() {
        let cleaned = nicknames.filter { !$0.value.isEmpty }
        if let data = try? JSONEncoder().encode(cleaned) {
            iCloudStore.set(data, forKey: nicknamesKey)
            iCloudStore.synchronize()
        }
    }

    // MARK: - Contact Activity Status

    enum ContactStatus {
        case active, recent, stale, offline
    }

    func contactStatus(for contact: Contact) -> ContactStatus {
        let now = Date().timeIntervalSince1970
        let lastSeen = TimeInterval(contact.lastAdvert)

        // Also check messages for most recent activity
        var latest = lastSeen
        if let activityDate = activityDateProvider?(contact.publicKeyPrefix) {
            latest = max(latest, activityDate.timeIntervalSince1970)
        }

        guard latest > 1_000_000_000 else { return .offline }
        let elapsed = now - latest

        if contact.type == .repeater || contact.type == .room {
            if elapsed < 6 * 3600 { return .active }
            if elapsed < 12 * 3600 { return .recent }
            if elapsed < 48 * 3600 { return .stale }
            return .offline
        } else {
            if elapsed < 1 * 3600 { return .active }
            if elapsed < 6 * 3600 { return .recent }
            if elapsed < 24 * 3600 { return .stale }
            return .offline
        }
    }

    func contactStatusColor(for contact: Contact) -> Color {
        switch contactStatus(for: contact) {
        case .active: return .green
        case .recent: return .yellow
        case .stale: return .gray
        case .offline: return .red
        }
    }

    // MARK: - Contact Notes

    func note(for contact: Contact) -> String {
        let key = contact.publicKey.map { String(format: "%02x", $0) }.joined()
        return contactNotes[key] ?? ""
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

    func hasNote(for contact: Contact) -> Bool {
        let key = contact.publicKey.map { String(format: "%02x", $0) }.joined()
        return contactNotes[key] != nil && !contactNotes[key]!.isEmpty
    }

    private var notesKey: String {
        let radioKey = radioPublicKeyHexProvider?() ?? ""
        return radioKey.isEmpty ? "contactNotes" : "notes.\(String(radioKey.prefix(12)))"
    }

    func loadContactNotesFromiCloud() {
        if let data = iCloudStore.data(forKey: notesKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            contactNotes = decoded
            return
        }

        contactNotes = [:]
    }

    private func saveContactNotesToiCloud() {
        if let data = try? JSONEncoder().encode(contactNotes) {
            iCloudStore.set(data, forKey: notesKey)
            iCloudStore.synchronize()
        }
    }

    // MARK: - Contact Groups

    struct ContactGroup: Codable, Identifiable {
        let id: UUID
        var name: String
        var emoji: String
        var memberPubkeys: [String]

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

    // MARK: - Favourites

    func toggleFavourite(for contact: Contact) {
        var newFlags = contact.flags
        if contact.isFavourite {
            newFlags &= ~0x01
        } else {
            newFlags |= 0x01
        }

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
        sendCommand?(frame, "UPDATE_CONTACT_FLAGS")

        if let index = contacts.firstIndex(where: { $0.publicKeyPrefix == contact.publicKeyPrefix }) {
            contacts[index] = contact.withFlags(newFlags)
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
        sendCommand?(frame, "UPDATE_CONTACT_FLAGS")

        if let index = contacts.firstIndex(where: { $0.publicKeyPrefix == contact.publicKeyPrefix }) {
            contacts[index] = contact.withFlags(newFlags)
        }
    }

    // MARK: - Contact Management

    func removeContact(_ contact: Contact) {
        let frame = MeshCoreProtocol.buildRemoveContact(publicKey: contact.publicKey)
        sendCommand?(frame, "REMOVE_CONTACT")
        contacts.removeAll { $0.publicKeyPrefix == contact.publicKeyPrefix }
        // Clean up all local data for this contact
        setNickname("", for: contact)
        setNote("", for: contact)
        clearMessagesForContact?(contact.publicKeyPrefix)
    }

    func resetPath(for contact: Contact) {
        DebugLogger.shared.log("PATH RESET: \(contact.name) — will flood until path discovered", level: .tx)
        let frame = MeshCoreProtocol.buildResetPath(publicKey: contact.publicKey)
        sendCommand?(frame, "RESET_PATH")

        if let index = contacts.firstIndex(where: { $0.publicKeyPrefix == contact.publicKeyPrefix }) {
            contacts[index] = Contact(
                publicKey: contact.publicKey,
                name: contact.name,
                type: contact.type,
                flags: contact.flags,
                outPathLen: -1,
                outPath: Data(),
                lastAdvert: contact.lastAdvert,
                latitude: contact.latitude,
                longitude: contact.longitude,
                lastmod: contact.lastmod
            )
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self?.requestDebouncedIncrementalSync()
        }
    }

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
        sendCommand?(frame, "SET_CONTACT_PATH(len=\(pathLen))")

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

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.requestDebouncedIncrementalSync()
        }
    }

    func shareContact(_ contact: Contact) {
        let frame = MeshCoreProtocol.buildShareContact(publicKey: contact.publicKey)
        sendCommand?(frame, "SHARE_CONTACT")
    }

    // MARK: - Pending Contacts

    func acceptPendingContact(_ contact: Contact) {
        pendingNewContacts.removeAll { $0.publicKeyPrefix == contact.publicKeyPrefix }
        if !contacts.contains(where: { $0.publicKeyPrefix == contact.publicKeyPrefix }) {
            contacts.append(contact)
        }
    }

    func rejectPendingContact(_ contact: Contact) {
        pendingNewContacts.removeAll { $0.publicKeyPrefix == contact.publicKeyPrefix }
        let frame = MeshCoreProtocol.buildRemoveContact(publicKey: contact.publicKey)
        sendCommand?(frame, "REJECT_PENDING_CONTACT")
    }

    // MARK: - Contact Sync (from response handling)

    func handleContactsStart(count: UInt32) {
        Self.logger.info("Contacts sync starting: \(count) contacts expected")
        DebugLogger.shared.log("Contacts sync: \(count) expected", level: .info)
        expectedContactCount = count
        incomingContacts = []
    }

    func handleContact(_ contact: Contact) {
        let c = contactWithTimestamp(contact)
        Self.logger.debug("Received contact: \(c.name) type=\(c.type.rawValue)")
        incomingContacts.append(c)
    }

    /// Finalize contact sync. Returns true if channel sync should be triggered.
    func handleEndOfContacts(lastmod: UInt32) -> Bool {
        Self.logger.info("Contacts sync complete: \(self.incomingContacts.count) contacts, lastmod=\(lastmod), incremental=\(self.isIncrementalContactSync)")
        DebugLogger.shared.log("Contacts done: \(self.incomingContacts.count) synced", level: .info)
        if isIncrementalContactSync {
            if !incomingContacts.isEmpty {
                // Dictionary-based merge: O(n+m) instead of O(n*m)
                var indexByPrefix: [Data: Int] = [:]
                for (i, c) in contacts.enumerated() {
                    indexByPrefix[c.publicKeyPrefix] = i
                }
                var merged = contacts
                for incoming in incomingContacts {
                    if let idx = indexByPrefix[incoming.publicKeyPrefix] {
                        merged[idx] = incoming
                    } else {
                        indexByPrefix[incoming.publicKeyPrefix] = merged.count
                        merged.append(incoming)
                    }
                }
                contacts = merged
            }
        } else {
            contacts = incomingContacts
        }
        incomingContacts = []
        lastContactsSync = lastmod
        let wasFullSync = !isIncrementalContactSync
        isIncrementalContactSync = false
        isSyncingContacts = false

        #if canImport(CoreSpotlight)
        indexContactsForSpotlight()
        #endif

        return wasFullSync
    }

    /// Ensure lastAdvert is set — if firmware sends 0, stamp with current time.
    private func contactWithTimestamp(_ contact: Contact) -> Contact {
        guard contact.lastAdvert < 1_000_000_000 else { return contact }
        let now = UInt32(Date().timeIntervalSince1970)
        return Contact(
            publicKey: contact.publicKey, name: contact.name, type: contact.type,
            flags: contact.flags, outPathLen: contact.outPathLen, outPath: contact.outPath,
            lastAdvert: now, latitude: contact.latitude, longitude: contact.longitude,
            lastmod: contact.lastmod
        )
    }

    func handleAdvert(_ contact: Contact) {
        let c = contactWithTimestamp(contact)
        if let idx = contacts.firstIndex(where: { $0.publicKeyPrefix == c.publicKeyPrefix }) {
            contacts[idx] = c
            DebugLogger.shared.log("ADVERT: updated \(c.name) lastAdvert=\(c.lastAdvert)", level: .rx)
        } else {
            contacts.append(c)
            DebugLogger.shared.log("ADVERT: new contact \(c.name) lastAdvert=\(c.lastAdvert)", level: .rx)
        }
    }

    func handleNewAdvert(_ contact: Contact, isInBackground: Bool) {
        let c = contactWithTimestamp(contact)
        Self.logger.info("PUSH NewAdvert (manual_add): \(c.name)")
        DebugLogger.shared.log("PUSH NewAdvert: \(c.name)", level: .rx)
        if !pendingNewContacts.contains(where: { $0.publicKeyPrefix == c.publicKeyPrefix }) {
            pendingNewContacts.append(c)
            if isInBackground && NotificationPreferences.shared.notifyNewContacts {
                postEventNotification?("New Contact Discovered", c.name, "contacts")
            }
        }
    }

    func handleContactDeleted(publicKey: Data) {
        let keyPrefix = publicKey.prefix(6)
        let name = contacts.first(where: { $0.publicKeyPrefix == keyPrefix })?.name ?? "Unknown"
        Self.logger.info("Contact deleted by device: \(name)")
        contacts.removeAll { $0.publicKeyPrefix == keyPrefix }
    }

    // MARK: - Path Hash Resolution

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

    // MARK: - Contact Requests

    func requestContacts(fullSync: Bool = false) {
        let since: UInt32 = fullSync ? 0 : lastContactsSync
        isIncrementalContactSync = !fullSync && since > 0
        isSyncingContacts = true
        sendCommand?(MeshCoreProtocol.buildGetContacts(since: since), "GET_CONTACTS(since:\(since))")
    }

    func requestDebouncedIncrementalSync() {
        contactSyncDebounceTask?.cancel()
        contactSyncDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.requestContacts()
        }
    }

    // MARK: - Spotlight

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
    #endif

    // MARK: - iCloud Changes

    private func observeiCloudChanges() {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: iCloudStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Only reload nicknames/notes if a radio is connected (key is scoped)
                if let radioKey = self?.radioPublicKeyHexProvider?(), !radioKey.isEmpty {
                    self?.loadNicknamesFromiCloud()
                    self?.loadContactNotesFromiCloud()
                }
                self?.loadContactGroupsFromiCloud()
            }
        }
    }

    // MARK: - Reset

    func reset() {
        contactSyncDebounceTask?.cancel()
        isSyncingContacts = false
        isIncrementalContactSync = false
        lastContactsSync = 0
        incomingContacts = []
        pendingNewContacts = []
        contacts = []
        nicknames = [:]
        contactNotes = [:]
    }
}
