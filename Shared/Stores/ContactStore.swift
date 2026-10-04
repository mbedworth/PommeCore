//
//  ContactStore.swift
//  PommeCore
//
//  Contacts, nicknames, notes, groups, activity status, and Spotlight indexing.
//
//  Created by Michael P. Bedworth on 3/20/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import SwiftUI
import os.log
#if canImport(CoreSpotlight)
import CoreSpotlight
import UniformTypeIdentifiers
#endif
import MeshCoreKit

/// Observable store for contacts, nicknames, notes, groups, and activity status.
/// Extracted from PommeCoreViewModel to enable fine-grained view observation.
/// What an orphan sweep would remove, so the user can see it before agreeing.
///
/// The sweep is irreversible and once ran by itself, on an inference about its
/// own authority, and permanently deleted conversations. It is user-initiated
/// now, and this is what makes that meaningful: a count the user reads first.
/// Messages and telemetry are reported separately from the small per-contact
/// entries because they are what people care about losing.
struct OrphanReport {
    var positionTrails = 0
    var mutes = 0
    var nicknames = 0
    var notes = 0
    var groupMemberships = 0
    var telemetryContacts = 0
    var telemetrySnapshots = 0
    var messageConversations = 0
    var messages = 0

    /// Per-contact odds and ends — small, and nobody will miss them.
    var minorEntries: Int { positionTrails + mutes + nicknames + notes + groupMemberships }
    var total: Int { minorEntries + telemetryContacts + messageConversations }
    var isEmpty: Bool { total == 0 }
}

@MainActor @Observable
final class ContactStore {
    private static let logger = Logger(subsystem: "com.pommecore", category: "ContactStore")

    // MARK: - Public State

    var contacts: [Contact] = []
    var pendingNewContacts: [Contact] = []
    var contactGroups: [ContactGroup] = []
    var mutedContacts: Set<String> = []

    // MARK: - Position History

    struct PositionPoint: Codable {
        let latitude: Double
        let longitude: Double
        let timestamp: Date
    }

    /// Position history per contact (keyed by pubkey hex). Max 50 points per contact.
    var positionHistory: [String: [PositionPoint]] = [:]
    private let maxPositionPoints = 50

    // MARK: - Dependencies (set by coordinator)

    /// Closure to send a command frame to the device.
    var sendCommand: ((Data, String) -> Void)?

    /// Closure to get latest activity date for a contact (checks messages).
    var activityDateProvider: ((Data) -> Date?)?

    /// Closure to clear messages when a contact is deleted.
    var clearMessagesForContact: ((Data) -> Void)?
    /// Drops a deleted contact's telemetry history (wired to RFMonitorStore).
    var clearTelemetryForContact: ((Data) -> Void)?
    /// Stores a snapshot before a destructive bulk operation (wired to
    /// ContactBackupStore).
    /// Returns whether the snapshot reached disk. A bulk delete must not
    /// proceed on `false`.
    var backupContacts: ((ContactBackup) -> Bool)?
    /// Drops telemetry for every contact outside the given live key-prefix set,
    /// returning how many were removed.
    var purgeOrphanedTelemetry: ((Set<Data>) -> Int)?
    /// Drops persisted messages and drafts for every contact outside the given
    /// live key-prefix set, returning how many were removed.
    var purgeOrphanedMessages: ((Set<Data>) -> Int)?
    /// Counts what `purgeOrphanedTelemetry` would drop, dropping nothing.
    var countOrphanedTelemetry: ((Set<Data>) -> (contacts: Int, snapshots: Int))?
    /// Counts what `purgeOrphanedMessages` would drop, dropping nothing.
    var countOrphanedMessages: ((Set<Data>) -> (conversations: Int, messages: Int))?

    /// Closure to post an event notification.
    var postEventNotification: ((String, String, String) -> Void)?

    /// Closure to get the connected radio's public key hex (for per-radio data isolation).
    var radioPublicKeyHexProvider: (() -> String)?

    /// Whether a transport is currently connected.
    ///
    /// Used to stop a paced burst of contact frames the moment the link drops,
    /// instead of writing the remainder into nothing — which is exactly how a
    /// profile import lost 4 of 11 adds and still reported success.
    var isConnectedProvider: (() -> Bool)?

    /// Surfaces a message to the user (wired to `ConnectionManager.lastErrorMessage`).
    var reportError: ((String) -> Void)?

    // MARK: - Contact write verification

    /// Which way a pending bulk contact write goes.
    enum ContactWriteDirection {
        case add
        case remove

        /// Whether a contact still appearing in the radio's list means the
        /// write did not take.
        func isOutstanding(presentOnRadio: Bool) -> Bool {
            switch self {
            case .add: return !presentOnRadio      // should be there, is not
            case .remove: return presentOnRadio    // should be gone, is not
            }
        }
    }

    /// A bulk contact write awaiting confirmation from the radio.
    private struct PendingContactWrite {
        let direction: ContactWriteDirection
        let contacts: [Contact]
        let pass: Int
        /// The radio this was meant for. A pending write survives a
        /// reconnect, so it must not be applied to a different radio.
        let radioKeyHex: String
        /// When it was queued, so a write that never got verified cannot be
        /// resurrected much later against an unrelated contact list.
        let createdAt: Date
        /// Shown to the user if every pass fails.
        let failureMessage: (Int) -> String
    }

    private var pendingContactWrite: PendingContactWrite?

    /// How many times to re-send dropped writes before telling the user.
    ///
    /// Three because hardware showed a single unpaced burst losing half its
    /// writes: one retry could plausibly drop again, while a path that keeps
    /// retrying forever would hammer the radio over a write it may be
    /// refusing for a reason we cannot see.
    private static let maxContactWritePasses = 3

    /// How long a pending write stays eligible for retry.
    ///
    /// It survives a disconnect on purpose — a link dropping mid-burst is
    /// exactly when the retry matters — but verification only runs when a full
    /// sync completes and is accepted, so an entry can otherwise sit
    /// indefinitely. Judged against a sync days later it would act on a list
    /// that has moved on: re-deleting a contact the user has since re-added
    /// from an advert, or re-adding one they have since deleted. Five minutes
    /// covers a reconnect and the sync that follows it, and nothing longer is
    /// a reconnect.
    private static let pendingWriteLifetime: TimeInterval = 300

    /// Spacing between contact frames.
    private static let contactFrameSpacing: UInt64 = 150_000_000

    // MARK: - Private State

    private let iCloudStore = NSUbiquitousKeyValueStore.default
    private var nicknames: [String: String] = [:]
    private var contactNotes: [String: String] = [:]

    // Contact sync state
    var incomingContacts: [Contact] = []
    var isSyncingContacts = false
    var isIncrementalContactSync = false
    var lastContactsSync: UInt32 = 0

    /// Whether a full contact sync has completed since the radio connected.
    ///
    /// The orphan sweep deletes data keyed to contacts that are missing from
    /// the list, so it is only safe when the list is known to be the radio's
    /// whole list. An incremental sync does not establish that, and neither
    /// does a cached list from a previous session. Cleared by `reset()` on
    /// every disconnect, so it never outlives the connection that earned it.
    private(set) var hasCompletedFullContactSync = false
    var expectedContactCount: UInt32 = 0
    private var contactSyncDebounceTask: Task<Void, Never>?

    // MARK: - Blocked Contacts

    private var blockedPubkeys: Set<String> = []

    func isBlocked(_ contact: Contact) -> Bool {
        blockedPubkeys.contains(contact.publicKey.hexCompact)
    }

    func isBlocked(publicKeyPrefix: Data) -> Bool {
        contacts.first(where: { $0.publicKeyPrefix == publicKeyPrefix })
            .map { isBlocked($0) } ?? false
    }

    func blockContact(_ contact: Contact) {
        blockedPubkeys.insert(contact.publicKey.hexCompact)
        saveBlockedToiCloud()
    }

    func unblockContact(_ contact: Contact) {
        blockedPubkeys.remove(contact.publicKey.hexCompact)
        saveBlockedToiCloud()
    }

    var blockedContacts: [Contact] {
        contacts.filter { isBlocked($0) }
    }

    func loadBlockedFromiCloud() {
        if let list = iCloudStore.loadCodable([String].self, forKey: "blockedContacts") {
            blockedPubkeys = Set(list)
        }
    }

    private func saveBlockedToiCloud() {
        guard iCloudSyncEnabled else { return }
        iCloudStore.saveCodable(Array(blockedPubkeys), forKey: "blockedContacts")
    }

    // MARK: - Init

    init() {
        // Don't load nicknames/notes at init — radio pubkey isn't known yet.
        // They are loaded in handleSelfInfo when the radio connects.
        loadContactGroupsFromiCloud()
        loadMutedContactsFromiCloud()
        loadBlockedFromiCloud()
        loadPositionHistory()
        observeiCloudChanges()
    }

    // MARK: - Sorted Contacts

    var sortedContacts: [Contact] {
        sortedContacts(byLastSeen: false)
    }

    /// Composite last-activity timestamp: max(lastAdvert, last message activity).
    func lastActivityTimestamp(for contact: Contact) -> TimeInterval {
        var latest = TimeInterval(contact.lastAdvert)
        if let activityDate = activityDateProvider?(contact.publicKeyPrefix) {
            latest = max(latest, activityDate.timeIntervalSince1970)
        }
        return latest
    }

    func sortedContacts(byLastSeen: Bool) -> [Contact] {
        // Every sort key is computed once per contact, not once per
        // comparison.
        //
        // This used to call `lastActivityTimestamp` from inside the
        // comparator, and that walks every message stored for the contact. A
        // sort makes O(n log n) comparisons and each one did two of those
        // scans, so 100 contacts holding 500 messages each came to hundreds of
        // thousands of message iterations — recomputed on every render of the
        // contact list, which a 60-second timer re-renders anyway, with
        // `byLastSeen` on by default. The name path was cheaper but not cheap:
        // it built two emoji-stripped strings per comparison.
        //
        // Decorating first makes it n key computations plus a sort over
        // pre-computed values.
        struct SortKey {
            let contact: Contact
            let isFavourite: Bool
            let isUnidentified: Bool
            let activity: TimeInterval
            let name: String
        }

        let keys = contacts.compactMap { contact -> SortKey? in
            guard !isBlocked(contact) else { return nil }
            return SortKey(
                contact: contact,
                isFavourite: contact.isFavourite,
                isUnidentified: contact.isUnidentified,
                activity: byLastSeen ? lastActivityTimestamp(for: contact) : 0,
                name: byLastSeen ? "" : displayName(for: contact).strippingEmoji
            )
        }

        return keys.sorted { a, b in
            if a.isFavourite != b.isFavourite {
                return a.isFavourite
            }
            // Nodes that have not identified themselves sort below real contacts in
            // both modes — they carry no name and nothing to act on yet.
            if a.isUnidentified != b.isUnidentified {
                return b.isUnidentified
            }
            if byLastSeen {
                return a.activity > b.activity
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }.map(\.contact)
    }

    // MARK: - Nicknames

    func setNickname(_ nickname: String, for contact: Contact) {
        let key = contact.publicKey.hexCompact
        let trimmed = String(nickname.prefix(32))
        if trimmed.isEmpty {
            nicknames.removeValue(forKey: key)
        } else {
            nicknames[key] = trimmed
        }
        saveNicknamesToiCloud()
    }

    func nickname(for contact: Contact) -> String? {
        let key = contact.publicKey.hexCompact
        guard let value = nicknames[key], !value.isEmpty else { return nil }
        return value
    }

    func displayName(for contact: Contact) -> String {
        if let nick = nickname(for: contact), !nick.isEmpty { return nick }
        if !contact.name.isEmpty { return contact.name }
        let prefix = Data(contact.publicKey.prefix(4)).hexCompact
        // Nodes the radio has heard from but that have not advertised a name yet
        // (firmware 1.17+ returns these from CMD_GET_CONTACTS) — say so, rather than
        // showing a bare hex string that looks like a broken contact.
        if contact.isUnidentified {
            return String(localized: "Unknown node") + " \u{00B7} " + prefix
        }
        // Fallback for contacts with no name (e.g. factory-reset or new radios)
        return prefix
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
        if let decoded: [String: String] = iCloudStore.loadCodable([String: String].self, forKey: nicknamesKey) {
            nicknames = decoded
                .filter { !$0.value.isEmpty }
                .mapValues { $0.count > 32 ? String($0.prefix(32)) : $0 }
            return
        }

        nicknames = [:]
    }

    private func saveNicknamesToiCloud() {
        guard iCloudSyncEnabled else { return }
        let cleaned = nicknames.filter { !$0.value.isEmpty }
        iCloudStore.saveCodable(cleaned, forKey: nicknamesKey)
    }

    // MARK: - Contact Activity Touch

    /// Update a contact's lastAdvert to now. Call this on any activity that proves
    /// the contact is alive: message received, ACK, login success, CLI response.
    func touchContact(publicKeyPrefix: Data) {
        guard let idx = contacts.firstIndex(where: { $0.publicKeyPrefix == publicKeyPrefix }) else { return }
        let now = Date().epochUInt32
        guard contacts[idx].lastAdvert < now else { return } // already current
        // Replace the full struct to ensure @Observable detects the change.
        // In-place struct field mutation may not always trigger SwiftUI view invalidation.
        var updated = contacts[idx]
        updated.lastAdvert = now
        contacts[idx] = updated
    }

    // MARK: - Contact Activity Status

    enum ContactStatus {
        case active, recent, stale, offline

        /// Status colour, per the colour standards in the development guide.
        var color: Color {
            switch self {
            case .active: return MeshTheme.statusGood
            case .recent: return MeshTheme.statusCaution
            case .stale: return MeshTheme.statusIdle
            case .offline: return MeshTheme.statusBad
            }
        }

        /// A glyph distinguishable by silhouette alone, for Differentiate
        /// Without Color. Status was previously carried by colour only, which
        /// is invisible to the ~8% of men with red/green colour blindness —
        /// and active/offline were exactly green against red.
        var symbolName: String {
            switch self {
            case .active: return "checkmark.circle.fill"
            case .recent: return "clock.fill"
            case .stale: return "moon.zzz.fill"
            case .offline: return "xmark.circle.fill"
            }
        }

        /// Spoken description for VoiceOver.
        var label: String {
            switch self {
            case .active: return String(localized: "active")
            case .recent: return String(localized: "recently seen")
            case .stale: return String(localized: "stale")
            case .offline: return String(localized: "offline")
            }
        }
    }

    func contactStatus(for contact: Contact) -> ContactStatus {
        let now = Date().timeIntervalSince1970
        let latest = lastActivityTimestamp(for: contact)

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
        contactStatus(for: contact).color
    }

    // MARK: - Path hops

    /// One hop in a routed path: the hash the radio reported, and the contact
    /// it names when that contact is known.
    struct ResolvedHop {
        let hash: Data
        let contact: Contact?

        /// What to show when the hop cannot be matched to a contact.
        var fallbackLabel: String { hash.hexCompact.uppercased() }
    }

    /// Resolve a path's hop hashes to the repeaters they name.
    ///
    /// Each hop is the first `hashSize` bytes of a repeater's public key, so a
    /// hop can be matched against the contact list directly. A hop resolves to
    /// nil when that repeater is not a known contact — which is ordinary, not
    /// an error: the mesh routes through nodes this radio has never adverted
    /// with. Callers must handle a nil rather than dropping it, because the
    /// hops are ordered and a silent drop misrepresents the route.
    func resolveHops(pathBytes: Data, hopCount: Int, hashSize: Int) -> [ResolvedHop] {
        guard !pathBytes.isEmpty, hopCount > 0, hashSize > 0 else { return [] }
        return (0..<hopCount).compactMap { i in
            let start = i * hashSize
            let end = start + hashSize
            guard end <= pathBytes.count else { return nil }
            let hash = Data(pathBytes[start..<end])
            let match = contacts.first { contact in
                contact.type == .repeater && contact.publicKeyPrefix.prefix(hashSize) == hash
            }
            return ResolvedHop(hash: hash, contact: match)
        }
    }

    func contactStatusLabel(for contact: Contact) -> String {
        contactStatus(for: contact).label
    }

    /// Glyph for this contact's status, for Differentiate Without Color.
    func contactStatusSymbol(for contact: Contact) -> String {
        contactStatus(for: contact).symbolName
    }

    // MARK: - Contact Notes

    func note(for contact: Contact) -> String {
        let key = contact.publicKey.hexCompact
        return contactNotes[key] ?? ""
    }

    func setNote(_ note: String, for contact: Contact) {
        let key = contact.publicKey.hexCompact
        if note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            contactNotes.removeValue(forKey: key)
        } else {
            contactNotes[key] = note
        }
        saveContactNotesToiCloud()
    }

    func hasNote(for contact: Contact) -> Bool {
        let key = contact.publicKey.hexCompact
        return contactNotes[key] != nil && !contactNotes[key]!.isEmpty
    }

    private var notesKey: String {
        let radioKey = radioPublicKeyHexProvider?() ?? ""
        return radioKey.isEmpty ? "contactNotes" : "notes.\(String(radioKey.prefix(12)))"
    }

    func loadContactNotesFromiCloud() {
        if let decoded: [String: String] = iCloudStore.loadCodable([String: String].self, forKey: notesKey) {
            contactNotes = decoded
            return
        }

        contactNotes = [:]
    }

    private func saveContactNotesToiCloud() {
        guard iCloudSyncEnabled else { return }
        iCloudStore.saveCodable(contactNotes, forKey: notesKey)
    }

    // MARK: - Contact Groups

    enum GroupNotifyMode: String, Codable, CaseIterable {
        case all = "All Messages"
        case priority = "Priority"
        case muted = "Muted"

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = GroupNotifyMode(rawValue: raw) ?? .all
        }
    }

    enum GroupSound: String, Codable, CaseIterable {
        case `default` = "Default"
        case chime = "Chime"
        case pulse = "Pulse"
        case alert = "Alert"
        case none = "None"

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = GroupSound(rawValue: raw) ?? .default
        }
    }

    struct ContactGroup: Codable, Identifiable {
        let id: UUID
        var name: String
        var emoji: String
        var memberPubkeys: [String]
        var notifyMode: GroupNotifyMode
        var sound: GroupSound

        init(id: UUID = UUID(), name: String, emoji: String = "", memberPubkeys: [String] = [],
             notifyMode: GroupNotifyMode = .all, sound: GroupSound = .default) {
            self.id = id
            self.name = name
            self.emoji = emoji
            self.memberPubkeys = memberPubkeys
            self.notifyMode = notifyMode
            self.sound = sound
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id           = try c.decode(UUID.self, forKey: .id)
            name         = try c.decode(String.self, forKey: .name)
            emoji        = try c.decodeIfPresent(String.self, forKey: .emoji) ?? ""
            memberPubkeys = try c.decodeIfPresent([String].self, forKey: .memberPubkeys) ?? []
            notifyMode   = try c.decodeIfPresent(GroupNotifyMode.self, forKey: .notifyMode) ?? .all
            sound        = try c.decodeIfPresent(GroupSound.self, forKey: .sound) ?? .default
        }
    }

    func loadContactGroupsFromiCloud() {
        guard let decoded = iCloudStore.loadCodable([ContactGroup].self, forKey: "contactGroups") else { return }
        contactGroups = decoded
    }

    private func saveContactGroupsToiCloud() {
        guard iCloudSyncEnabled else { return }
        iCloudStore.saveCodable(contactGroups, forKey: "contactGroups")
    }

    func addContactGroup(name: String, emoji: String) {
        contactGroups.append(ContactGroup(name: name, emoji: emoji))
        saveContactGroupsToiCloud()
    }

    func deleteContactGroup(_ group: ContactGroup) {
        contactGroups.removeAll { $0.id == group.id }
        saveContactGroupsToiCloud()
    }

    func renameContactGroup(_ group: ContactGroup, name: String, emoji: String) {
        if let idx = contactGroups.firstIndex(where: { $0.id == group.id }) {
            contactGroups[idx].name = name
            contactGroups[idx].emoji = emoji
            saveContactGroupsToiCloud()
        }
    }

    func addContactToGroup(_ contact: Contact, group: ContactGroup) {
        let pubkeyHex = contact.publicKey.hexCompact
        if let idx = contactGroups.firstIndex(where: { $0.id == group.id }) {
            if !contactGroups[idx].memberPubkeys.contains(pubkeyHex) {
                contactGroups[idx].memberPubkeys.append(pubkeyHex)
                saveContactGroupsToiCloud()
            }
        }
    }

    func removeContactFromGroup(_ contact: Contact, group: ContactGroup) {
        let pubkeyHex = contact.publicKey.hexCompact
        if let idx = contactGroups.firstIndex(where: { $0.id == group.id }) {
            contactGroups[idx].memberPubkeys.removeAll { $0 == pubkeyHex }
            saveContactGroupsToiCloud()
        }
    }

    func contactsInGroup(_ group: ContactGroup) -> [Contact] {
        contacts.filter { contact in
            let hex = contact.publicKey.hexCompact
            return group.memberPubkeys.contains(hex)
        }
    }

    func setGroupNotifyMode(_ group: ContactGroup, mode: GroupNotifyMode) {
        if let idx = contactGroups.firstIndex(where: { $0.id == group.id }) {
            contactGroups[idx].notifyMode = mode
            saveContactGroupsToiCloud()
        }
    }

    func setGroupSound(_ group: ContactGroup, sound: GroupSound) {
        if let idx = contactGroups.firstIndex(where: { $0.id == group.id }) {
            contactGroups[idx].sound = sound
            saveContactGroupsToiCloud()
        }
    }

    /// Mute/unmute all members of a group.
    func setGroupMembersMuted(_ group: ContactGroup, muted: Bool) {
        for pubkey in group.memberPubkeys {
            if muted {
                mutedContacts.insert(pubkey)
            } else {
                mutedContacts.remove(pubkey)
            }
        }
        saveMutedContactsToiCloud()
    }

    // MARK: - Per-Contact Mute

    func isContactMuted(_ contact: Contact) -> Bool {
        mutedContacts.contains(contact.publicKey.hexCompact)
    }

    func toggleContactMuted(_ contact: Contact) {
        let key = contact.publicKey.hexCompact
        if mutedContacts.contains(key) {
            mutedContacts.remove(key)
        } else {
            mutedContacts.insert(key)
        }
        saveMutedContactsToiCloud()
    }

    /// Returns the most specific notification mode for a contact based on group membership.
    /// Priority > All > Muted. If contact is in multiple groups, highest priority wins.
    func effectiveNotifyMode(for contact: Contact) -> GroupNotifyMode {
        let hex = contact.publicKey.hexCompact
        if mutedContacts.contains(hex) { return .muted }
        var best: GroupNotifyMode = .all
        for group in contactGroups where group.memberPubkeys.contains(hex) {
            if group.notifyMode == .priority { return .priority }
            if group.notifyMode == .muted { best = .muted }
        }
        return best
    }

    /// Returns the notification sound for a contact based on group membership.
    func effectiveSound(for contact: Contact) -> GroupSound {
        let hex = contact.publicKey.hexCompact
        for group in contactGroups where group.memberPubkeys.contains(hex) {
            if group.sound != .default { return group.sound }
        }
        return .default
    }

    func loadMutedContactsFromiCloud() {
        if let array = iCloudStore.array(forKey: "mutedContacts") as? [String] {
            mutedContacts = Set(array)
        }
    }

    private func saveMutedContactsToiCloud() {
        guard iCloudSyncEnabled else { return }
        iCloudStore.set(Array(mutedContacts), forKey: "mutedContacts")
        iCloudStore.synchronize()
    }

    // MARK: - Position History

    /// Record a position update for a contact. Deduplicates if position hasn't changed.
    func recordPosition(for contact: Contact) {
        let lat = contact.latitude
        let lon = contact.longitude
        guard lat != 0 || lon != 0 else { return }

        let key = contact.publicKey.hexCompact
        var history = positionHistory[key] ?? []

        // Skip if same position as last recorded
        if let last = history.last,
           abs(last.latitude - lat) < 0.00001 && abs(last.longitude - lon) < 0.00001 {
            return
        }

        history.append(PositionPoint(latitude: lat, longitude: lon, timestamp: Date()))
        if history.count > maxPositionPoints {
            history.removeFirst(history.count - maxPositionPoints)
        }
        positionHistory[key] = history
        savePositionHistoryDebounced()
    }

    func positionTrail(for contact: Contact) -> [PositionPoint] {
        positionHistory[contact.publicKey.hexCompact] ?? []
    }

    private var positionSavePending = false

    private func savePositionHistoryDebounced() {
        guard !positionSavePending else { return }
        positionSavePending = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000) // batch every 10s
            self.positionSavePending = false
            self.savePositionHistory()
        }
    }

    func loadPositionHistory() {
        let url = Self.positionHistoryFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            positionHistory = try JSONDecoder().decode([String: [PositionPoint]].self, from: data)
        } catch {
            DebugLogger.shared.log("POSITION: failed to load history: \(error.localizedDescription)", level: .warning)
        }
    }

    private func savePositionHistory() {
        // Snapshot on the main actor, then encode and write off it — capped at
        // 50 points per contact this reaches a few hundred KB across a busy
        // mesh, and an atomic write of that on every 10s batch is a visible
        // hitch. Mirrors RFMonitorStore.saveTelemetryHistory().
        let snapshot = positionHistory
        let fileURL = Self.positionHistoryFileURL
        Task.detached(priority: .utility) {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                DebugLogger.shared.log("POSITION: failed to save history: \(error.localizedDescription)", level: .warning)
            }
        }
    }

    private static var positionHistoryFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = dir.appendingPathComponent("MeshCore", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("position_history.json")
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
            latitude: MeshCoreProtocol.microDegrees(contact.latitude),
            longitude: MeshCoreProtocol.microDegrees(contact.longitude)
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
            latitude: MeshCoreProtocol.microDegrees(contact.latitude),
            longitude: MeshCoreProtocol.microDegrees(contact.longitude)
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
        var dirty = PurgedStores()
        purgeLocalData(for: contact, dirty: &dirty)
        flushPurgeSaves(dirty)
    }

    /// Remove several contacts in one pass.
    ///
    /// Deleting in a loop over `removeContact` was correct but wasteful and
    /// unreliable at scale. Each call re-saved the entire position-history
    /// file and wrote to iCloud, so removing 50 contacts meant 50 encodes of
    /// the whole history and 50 key-value writes; and each sent its removal
    /// frame immediately, so the radio received a burst of 50 writes with no
    /// pacing or flow control, which can silently drop some. Dropped removals
    /// are invisible until the next sync, when the contact reappears.
    ///
    /// This mutates `contacts` once, purges all local data with the saves
    /// coalesced to one per store, and paces the outgoing frames.
    func removeContacts(_ toRemove: [Contact]) {
        guard toRemove.count > 1 else {
            if let only = toRemove.first { removeContact(only) }
            return
        }

        // Snapshot the *whole* list before anything is sent. Contacts live on
        // the radio, so removing them there is final — there is no undo, and
        // the configuration export carries radio settings and channels but not
        // contacts. Written synchronously: handing this to a task would race
        // the deletion it exists to protect against.
        //
        // The whole list rather than just the doomed ones, because the failure
        // worth protecting against is the selection being wrong.
        //
        // And the delete does not happen without it. A backup that silently
        // failed to write — disk full, encode error, closure never wired —
        // would leave this doing exactly the irreversible thing it exists to
        // make reversible. Refusing is safe: the contacts are still there and
        // the user can try again.
        let backedUp = backupContacts?(snapshot(reason: "deleting \(toRemove.count) contacts")) ?? false
        guard backedUp else {
            Self.logger.error("Bulk remove aborted: contact backup could not be written")
            DebugLogger.shared.log("Bulk delete cancelled — the backup could not be saved", level: .error)
            reportError?(String(localized: "Could not save a backup, so nothing was deleted. Free up some space and try again."))
            return
        }

        let prefixes = Set(toRemove.map(\.publicKeyPrefix))
        contacts.removeAll { prefixes.contains($0.publicKeyPrefix) }

        var dirty = PurgedStores()
        for contact in toRemove {
            purgeLocalData(for: contact, dirty: &dirty)
        }
        flushPurgeSaves(dirty)

        Self.logger.info("Bulk remove: \(toRemove.count) contacts")
        DebugLogger.shared.log("Removing \(toRemove.count) contacts", level: .tx)
        sendRemoveContactFrames(for: toRemove)
    }

    /// Capture the current contact list and everything keyed to it.
    func snapshot(reason: String) -> ContactBackup {
        var membership: [String: [String]] = [:]
        for group in contactGroups where !group.memberPubkeys.isEmpty {
            membership[group.name] = group.memberPubkeys
        }
        return ContactBackup(
            reason: reason,
            radioPublicKeyHex: radioPublicKeyHexProvider?() ?? "",
            contacts: contacts,
            nicknames: nicknames,
            notes: contactNotes,
            mutedContacts: Array(mutedContacts),
            groupMembership: membership
        )
    }

    /// Re-apply the app-side data from a backup: nicknames, notes, mute state
    /// and group membership.
    ///
    /// The contacts themselves go back to the radio and return through the
    /// normal sync, so this only restores what the app owns. Merges rather
    /// than replaces, so anything set since the backup is kept.
    func restoreLocalData(from backup: ContactBackup) {
        for (key, value) in backup.nicknames where nicknames[key] == nil {
            nicknames[key] = value
        }
        for (key, value) in backup.notes where contactNotes[key] == nil {
            contactNotes[key] = value
        }
        mutedContacts.formUnion(backup.mutedContacts)

        for (groupName, members) in backup.groupMembership {
            if let index = contactGroups.firstIndex(where: { $0.name == groupName }) {
                let existing = Set(contactGroups[index].memberPubkeys)
                contactGroups[index].memberPubkeys += members.filter { !existing.contains($0) }
            } else {
                contactGroups.append(ContactGroup(name: groupName, memberPubkeys: members))
            }
        }

        saveNicknamesToiCloud()
        saveContactNotesToiCloud()
        saveMutedContactsToiCloud()
        saveContactGroupsToiCloud()

        Self.logger.info("Restored local data for \(backup.contacts.count) contacts from backup")
    }

    /// Send CMD_REMOVE_CONTACT for each contact, spaced out.
    ///
    /// Binary frames are written straight to the transport with no queue or
    /// pacing, unlike the CLI path. Each removal makes the firmware update its
    /// persistent contact store, so a tight burst risks writes being dropped.
    /// The interval is deliberately conservative rather than measured; it can
    /// be tightened with `scripts/meshctl.sh` against real hardware.
    private func sendRemoveContactFrames(for toRemove: [Contact]) {
        Task { @MainActor [weak self] in
            await self?.sendContactWrite(
                toRemove, direction: .remove, label: "REMOVE_CONTACT", pass: 1,
                failureMessage: { count in
                    String(format: String(localized: "%d contacts could not be removed. The radio still has them \u{2014} try deleting again."), count)
                }
            )
        }
    }

    /// Send a bulk contact write, then check the radio actually applied it,
    /// retrying anything it dropped.
    ///
    /// Hardware showed why this cannot be left to pacing alone. Removals: 60
    /// frames written back to back left **30 contacts still on the radio**,
    /// with the following sync internally consistent, so nothing in any
    /// response said a thing was wrong. Adds: a profile import sent 7 of 11
    /// frames and then the BLE link dropped mid-burst — the remaining 4 were
    /// written into a dead connection, none of the 11 landed, and the UI still
    /// reported success.
    ///
    /// So the radio's own contact list is the signal, in both directions:
    /// whatever disagrees with what we asked for was not applied, and gets
    /// asked again.
    private func sendContactWrite(
        _ contacts: [Contact],
        direction: ContactWriteDirection,
        label: String,
        pass: Int,
        progress: ((Int, Int) -> Void)? = nil,
        failureMessage: @escaping (Int) -> String
    ) async {
        for (offset, contact) in contacts.enumerated() {
            // Stop the moment the link is gone rather than writing the rest
            // into nothing. Whatever has not been applied is picked up by the
            // verification pass once a sync is possible again.
            guard isConnectedProvider?() ?? true else {
                Self.logger.warning("\(label): link lost after \(offset) of \(contacts.count) frames — stopping")
                DebugLogger.shared.log("Connection lost part-way through \(label.lowercased())", level: .warning)
                break
            }
            let frame = direction == .add
                ? MeshCoreProtocol.buildAddUpdateContact(contact)
                : MeshCoreProtocol.buildRemoveContact(publicKey: contact.publicKey)
            sendCommand?(frame, label)
            progress?(offset + 1, contacts.count)
            if offset < contacts.count - 1 {
                try? await Task.sleep(nanoseconds: Self.contactFrameSpacing)
            }
        }

        // Let the firmware commit the last write before asking it to
        // enumerate, so responses are not still in flight when the contact
        // stream starts.
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        // Record the outstanding work before deciding whether a sync is even
        // possible, so a reconnect can still pick it up.
        pendingContactWrite = PendingContactWrite(
            direction: direction, contacts: contacts, pass: pass,
            radioKeyHex: radioPublicKeyHexProvider?() ?? "",
            createdAt: Date(),
            failureMessage: failureMessage
        )
        // Only ask for a sync if there is a link to answer it. Asking while
        // disconnected leaves `isSyncingContacts` set with nothing to clear
        // it — a spinner that never stops. The pending write above is picked
        // up by the sync that runs on reconnect.
        guard isConnectedProvider?() ?? true else {
            Self.logger.info("Link down — deferring verification to the reconnect sync")
            return
        }
        requestContacts(fullSync: true)
    }

    /// Re-send anything the radio's list says did not take.
    ///
    /// Called once a full sync completes, which is the only moment the radio's
    /// actual contact list is known. Returns without acting when there is
    /// nothing outstanding.
    func verifyPendingContactWrite() {
        discardPendingWriteIfStale()
        guard let pending = pendingContactWrite else { return }
        pendingContactWrite = nil

        let present = Set(contacts.map(\.publicKeyPrefix))
        let outstanding = pending.contacts.filter {
            pending.direction.isOutstanding(presentOnRadio: present.contains($0.publicKeyPrefix))
        }
        guard !outstanding.isEmpty else {
            if pending.pass > 1 {
                Self.logger.info("Contact write verified after \(pending.pass) passes")
            }
            return
        }

        let label = pending.direction == .add ? "ADD_CONTACT" : "REMOVE_CONTACT"

        guard pending.pass < Self.maxContactWritePasses else {
            // Out of retries. Say so plainly rather than leaving the user to
            // discover it — the list now shown is the radio's truth, so the
            // disagreement is real and silence would read as success.
            Self.logger.error("\(label): \(outstanding.count) contact(s) still wrong after \(pending.pass) passes — giving up")
            DebugLogger.shared.log(
                "\(outstanding.count) contact(s) could not be written — the radio disagrees. Try again.",
                level: .warning
            )
            reportError?(pending.failureMessage(outstanding.count))
            return
        }

        Self.logger.warning("\(label): \(outstanding.count) of \(pending.contacts.count) writes were dropped — retrying (pass \(pending.pass + 1))")
        DebugLogger.shared.log(
            "Radio disagrees on \(outstanding.count) contact(s) — resending",
            level: .warning
        )

        if pending.direction == .remove {
            // The sync that just completed put them back; they are on their
            // way out again.
            let keys = Set(outstanding.map(\.publicKeyPrefix))
            contacts.removeAll { keys.contains($0.publicKeyPrefix) }
        }

        Task { @MainActor [weak self] in
            await self?.sendContactWrite(
                outstanding, direction: pending.direction, label: label,
                pass: pending.pass + 1, failureMessage: pending.failureMessage
            )
        }
    }

    /// Drop a pending write that is no longer safe to act on.
    private func discardPendingWriteIfStale() {
        guard let pending = pendingContactWrite else { return }

        if Date().timeIntervalSince(pending.createdAt) > Self.pendingWriteLifetime {
            // Say so. This is the one discard the user needs to hear about:
            // the write was real, part of it may never have landed, and the
            // restore or import UI has already reported success. Staying quiet
            // here reproduces exactly the silent partial application the
            // verification pass exists to prevent.
            Self.logger.warning("Discarding pending contact write — too old to trust")
            DebugLogger.shared.log(
                "A contact write could not be verified before it expired", level: .warning
            )
            reportError?(pending.failureMessage(pending.contacts.count))
            pendingContactWrite = nil
            return
        }

        let current = radioPublicKeyHexProvider?() ?? ""
        guard !pending.radioKeyHex.isEmpty, !current.isEmpty,
              pending.radioKeyHex != current else { return }
        Self.logger.info("Discarding pending contact write — different radio")
        pendingContactWrite = nil
    }

    /// Add or update contacts on the radio, verifying they landed.
    ///
    /// Used by profile import and backup restore — both put contacts onto a
    /// radio, and both previously assumed every frame arrived.
    func addContacts(_ newContacts: [Contact], progress: ((Int, Int) -> Void)? = nil) async {
        guard !newContacts.isEmpty else { return }
        Self.logger.info("Adding \(newContacts.count) contacts")
        DebugLogger.shared.log("Adding \(newContacts.count) contacts", level: .tx)
        await sendContactWrite(
            newContacts, direction: .add, label: "ADD_CONTACT", pass: 1,
            progress: progress,
            failureMessage: { count in
                String(format: String(localized: "%d contacts could not be added. The radio did not accept them \u{2014} try again."), count)
            }
        )
    }


    /// Which persisted stores a purge touched, so saves happen once rather
    /// than once per contact.
    private struct PurgedStores {
        var positionHistory = false
        var muted = false
        var nicknames = false
        var notes = false
        var groups = false
    }

    private func flushPurgeSaves(_ dirty: PurgedStores) {
        if dirty.positionHistory { savePositionHistory() }
        if dirty.muted { saveMutedContactsToiCloud() }
        if dirty.nicknames { saveNicknamesToiCloud() }
        if dirty.notes { saveContactNotesToiCloud() }
        if dirty.groups { saveContactGroupsToiCloud() }
    }

    /// Remove every piece of per-contact state the app persists.
    ///
    /// Each collection here is keyed by public key and outlives `contacts`
    /// unless explicitly cleared, across UserDefaults, iCloud key-value
    /// storage, the Spotlight index and two on-disk JSON files. Leaving any of
    /// them behind means a deleted contact keeps a searchable Spotlight entry,
    /// and that its group membership, mute state, position trail and telemetry
    /// all reattach if the same key is added again later.
    ///
    /// Add to this function whenever a new per-contact collection is
    /// introduced.
    ///
    /// Records which stores it touched in `dirty` rather than saving as it
    /// goes, so a bulk delete writes each store once instead of once per
    /// contact. Callers must finish with `flushPurgeSaves`.
    private func purgeLocalData(for contact: Contact, dirty: inout PurgedStores) {
        let key = contact.publicKey.hexCompact

        // Mutated directly rather than through setNickname/setNote, which save
        // on every call.
        if nicknames.removeValue(forKey: key) != nil { dirty.nicknames = true }
        if contactNotes.removeValue(forKey: key) != nil { dirty.notes = true }

        clearMessagesForContact?(contact.publicKeyPrefix)
        // Telemetry is keyed by the 6-byte prefix, matching the recordTelemetry
        // call site — not by the full public key, which never matches.
        clearTelemetryForContact?(contact.publicKeyPrefix)

        if positionHistory.removeValue(forKey: key) != nil { dirty.positionHistory = true }
        if mutedContacts.remove(key) != nil { dirty.muted = true }

        for index in contactGroups.indices where contactGroups[index].memberPubkeys.contains(key) {
            contactGroups[index].memberPubkeys.removeAll { $0 == key }
            dirty.groups = true
        }

        removeContactFromSpotlight(pubkeyHex: key)
        // The fingerprint describes what is *indexed*, and that just changed
        // without a full index running. Leaving it set means a contact which
        // comes back later — a fresh advert, a manual re-add — produces the
        // same hash as before the delete, matches, and is skipped, so it stays
        // missing from Spotlight until something else perturbs the list.
        spotlightFingerprint = nil
    }

    /// Remove persisted per-contact data that no longer has a contact.
    ///
    /// Per-contact cleanup on delete only helps contacts deleted from now on.
    /// Anything removed before it existed left its position trail, mute state,
    /// group membership, nickname, note and telemetry behind, and nothing ever
    /// collected them. This reconciles what is persisted against the live
    /// contact list and drops the remainder.
    ///
    /// **User-initiated only, and only with a verified-complete contact list.**
    ///
    /// This was originally run automatically after every full sync, and it
    /// destroyed data: a truncated sync was accepted as the whole truth, so
    /// the sweep deleted messages, nicknames, notes, trails, mute state and
    /// telemetry for every contact missing from it. None of that is
    /// recoverable. The lesson is not that the guard needed to be smarter —
    /// it is that an irreversible pass over user data should not run by
    /// itself, inferring its own authority, to reclaim a few hundred
    /// kilobytes.
    ///
    /// Callers must pass `contactListVerifiedComplete: true`, which only
    /// holds when the caller knows a full sync delivered every contact the
    /// radio announced. `countOrphanedData()` reports what would be removed
    /// without removing it, so the user can be shown a number first.
    ///
    /// How many orphaned entries a sweep would remove, without removing any.
    ///
    /// Lets the user be shown a number and decide, instead of the app deciding
    /// for them. Counts only what this store owns; the cross-store totals are
    /// reported by the sweep itself.
    func countOrphanedData() -> OrphanReport {
        guard !contacts.isEmpty else { return OrphanReport() }
        let live = Set(contacts.map { $0.publicKey.hexCompact })
        let livePrefixes = Set(contacts.map(\.publicKeyPrefix))

        var report = OrphanReport()
        report.positionTrails = positionHistory.keys.filter { !live.contains($0) }.count
        report.mutes = mutedContacts.filter { !live.contains($0) }.count
        report.nicknames = nicknames.keys.filter { !live.contains($0) }.count
        report.notes = contactNotes.keys.filter { !live.contains($0) }.count
        report.groupMemberships = contactGroups.reduce(0) { total, group in
            total + group.memberPubkeys.filter { !live.contains($0) }.count
        }

        // The two that actually take space, and the two the user most needs
        // warning about before agreeing — a conversation is not recoverable.
        let telemetry = countOrphanedTelemetry?(livePrefixes) ?? (contacts: 0, snapshots: 0)
        report.telemetryContacts = telemetry.contacts
        report.telemetrySnapshots = telemetry.snapshots
        let messages = countOrphanedMessages?(livePrefixes) ?? (conversations: 0, messages: 0)
        report.messageConversations = messages.conversations
        report.messages = messages.messages

        return report
    }

    /// Idempotent: a second run over clean data removes nothing.
    @discardableResult
    func purgeOrphanedData(contactListVerifiedComplete: Bool) -> Int {
        guard contactListVerifiedComplete else {
            Self.logger.error("Orphan sweep refused — contact list not verified complete")
            return 0
        }
        guard !contacts.isEmpty else {
            Self.logger.info("Orphan sweep skipped — no contacts, refusing to treat that as authoritative")
            return 0
        }

        let liveHexKeys = Set(contacts.map { $0.publicKey.hexCompact })
        let livePrefixes = Set(contacts.map(\.publicKeyPrefix))
        var removed = 0

        let orphanedTrails = positionHistory.keys.filter { !liveHexKeys.contains($0) }
        for key in orphanedTrails { positionHistory.removeValue(forKey: key) }
        if !orphanedTrails.isEmpty { savePositionHistory() }
        removed += orphanedTrails.count

        let orphanedMutes = mutedContacts.filter { !liveHexKeys.contains($0) }
        if !orphanedMutes.isEmpty {
            mutedContacts.subtract(orphanedMutes)
            saveMutedContactsToiCloud()
            removed += orphanedMutes.count
        }

        let orphanedNicknames = nicknames.keys.filter { !liveHexKeys.contains($0) }
        for key in orphanedNicknames { nicknames.removeValue(forKey: key) }
        if !orphanedNicknames.isEmpty { saveNicknamesToiCloud() }
        removed += orphanedNicknames.count

        let orphanedNotes = contactNotes.keys.filter { !liveHexKeys.contains($0) }
        for key in orphanedNotes { contactNotes.removeValue(forKey: key) }
        if !orphanedNotes.isEmpty { saveContactNotesToiCloud() }
        removed += orphanedNotes.count

        var groupsChanged = false
        for index in contactGroups.indices {
            let stale = contactGroups[index].memberPubkeys.filter { !liveHexKeys.contains($0) }
            guard !stale.isEmpty else { continue }
            contactGroups[index].memberPubkeys.removeAll { stale.contains($0) }
            groupsChanged = true
            removed += stale.count
        }
        if groupsChanged { saveContactGroupsToiCloud() }

        // Telemetry and messages live in other stores and are keyed by the
        // 6-byte prefix, so they get the prefix set rather than the hex set.
        removed += purgeOrphanedTelemetry?(livePrefixes) ?? 0
        removed += purgeOrphanedMessages?(livePrefixes) ?? 0

        if removed > 0 {
            Self.logger.info("Orphan sweep removed \(removed) stale per-contact entries")
            DebugLogger.shared.log("Cleanup: removed \(removed) orphaned entries for deleted contacts", level: .info)
        }
        return removed
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
        let pathHex = pathData.isEmpty ? "(empty)" : pathData.hexCompact
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
            latitude: MeshCoreProtocol.microDegrees(contact.latitude),
            longitude: MeshCoreProtocol.microDegrees(contact.longitude)
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
        // What a finished sync means for the stored list is decided by
        // ContactSyncReducer, in MeshCoreKit, where it is covered by tests.
        // It used to be inline here, in the app target, out of reach of the
        // test suite — and it shipped a data-loss bug.
        let outcome = ContactSyncReducer.reduce(
            existing: contacts,
            incoming: incomingContacts,
            announced: Int(expectedContactCount),
            isIncremental: isIncrementalContactSync
        )

        let wasFullSync = !isIncrementalContactSync
        incomingContacts = []
        isIncrementalContactSync = false
        isSyncingContacts = false
        expectedContactCount = 0

        switch outcome {
        case .rejectTruncated(let received, let announced):
            // A shortfall against the announced count does not mean the radio
            // forgot those contacts, so keep the list and let the next sync
            // settle it.
            //
            // Not reproduced on hardware (firmware v1.17.1, `meshctl
            // bulkdelete`): even an unpaced 60-contact deletion produced a
            // self-consistent sync. The guard stays because the cost of being
            // wrong is asymmetric — accepting a short list once cascaded into
            // permanent data loss, while keeping a stale list self-corrects on
            // the next sync.
            Self.logger.error("Full sync truncated: \(received) of \(announced) contacts — keeping existing list")
            DebugLogger.shared.log(
                "Contacts sync incomplete (\(received)/\(announced)) — keeping existing contacts",
                level: .warning
            )
            return false

        case .rejectUnverifiable:
            Self.logger.error("Full sync would have emptied the contact list with no announced count — keeping existing list")
            DebugLogger.shared.log("Contacts sync returned none and announced none — keeping existing contacts", level: .warning)
            return false

        case .noChange:
            lastContactsSync = lastmod
            return wasFullSync

        case .merge(let result), .replace(let result):
            contacts = result
            lastContactsSync = lastmod
            // Only `.replace` is authoritative; nothing below deletes data
            // keyed by contact, and nothing here may start doing so without
            // checking for that case specifically.
        }

        // Record position history for contacts with coordinates
        for contact in contacts {
            recordPosition(for: contact)
        }

        #if canImport(CoreSpotlight)
        indexContactsForSpotlight()
        #endif

        // The radio's list is now known, which is the only moment a removal
        // can be confirmed. Anything we asked it to delete that it still
        // reports was dropped, not deleted.
        if wasFullSync {
            verifyPendingContactWrite()
        }

        // A full sync that reached here was not truncated and not rejected, so
        // the list is the radio's whole list. That is the one fact the orphan
        // sweep needs, and the only place it can be established.
        if wasFullSync { hasCompletedFullContactSync = true }

        // The orphan sweep is deliberately NOT run here. It used to be, on
        // every full sync, and that caused real data loss: a truncated sync
        // was accepted as authoritative, and the sweep then permanently
        // deleted messages, nicknames, notes, position trails, mute state and
        // telemetry for every contact missing from it. The reducer now stops
        // the truncated sync, but a destructive maintenance pass should not
        // depend on a single guard holding for its safety — the downside is
        // unrecoverable and the upside is reclaiming a few hundred kilobytes.
        // It is user-initiated, which also lets the user see what it found
        // before anything is removed.

        return wasFullSync
    }

    /// Ensure lastAdvert is set — if firmware sends 0, stamp with current time.
    private func contactWithTimestamp(_ contact: Contact) -> Contact {
        guard contact.lastAdvert < 1_000_000_000 else { return contact }
        let now = Date().epochUInt32
        return Contact(
            publicKey: contact.publicKey, name: contact.name, type: contact.type,
            flags: contact.flags, outPathLen: contact.outPathLen, outPath: contact.outPath,
            lastAdvert: now, latitude: contact.latitude, longitude: contact.longitude,
            lastmod: contact.lastmod
        )
    }

    func handleAdvert(_ contact: Contact) {
        let now = Date().epochUInt32
        if let idx = contacts.firstIndex(where: { $0.publicKeyPrefix == contact.publicKeyPrefix }) {
            if contact.name.isEmpty && contact.type == .unknown {
                // Pubkey-only advert (0x80 short form) — update timestamp on existing contact,
                // don't replace with skeleton data.
                contacts[idx].lastAdvert = now
                DebugLogger.shared.log("ADVERT: timestamp updated for \(contacts[idx].name)", level: .rx)
            } else {
                // Full contact advert — replace with new data
                let c = contactWithTimestamp(contact)
                contacts[idx] = c
                DebugLogger.shared.log("ADVERT: updated \(c.name) lastAdvert=\(c.lastAdvert)", level: .rx)
            }
        } else if !contact.name.isEmpty {
            // Only add new contacts if we have real data (not pubkey-only)
            let c = contactWithTimestamp(contact)
            contacts.append(c)
            DebugLogger.shared.log("ADVERT: new contact \(c.name) lastAdvert=\(c.lastAdvert)", level: .rx)
        } else {
            DebugLogger.shared.log("ADVERT: ignoring pubkey-only for unknown contact", level: .rx)
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

    /// The radio evicted a contact to make room, and told us.
    ///
    /// Deliberately does **not** run `purgeLocalData`, unlike `removeContact`.
    /// Eviction is the radio reclaiming space when its contact store fills; the
    /// user did not ask to forget this person, and the contact's next advert
    /// re-adds it, at which point messages, telemetry and position history all
    /// reconnect by key prefix. Purging here would destroy conversations nobody
    /// asked to delete, to reclaim space on a device that is not short of it.
    ///
    /// The cost is that data for a contact which never returns is orphaned.
    /// That is what the user-initiated sweep in Settings → Storage is for —
    /// bounded, visible, and the user's call rather than a side effect of the
    /// radio running out of room.
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
    /// Domain for every contact this app indexes, so the whole set can be
    /// replaced in one call.
    private static let spotlightDomain = "com.mbedworth.meshcore.contacts"

    /// Fingerprint of what is currently indexed, so an unchanged contact list
    /// does not get re-indexed.
    private var spotlightFingerprint: Int?

    func indexContactsForSpotlight() {
        // A full sync happens on every connect, and this used to delete the
        // whole Spotlight domain and rebuild it each time — hundreds of index
        // writes for a list that almost never changed between syncs. Hash what
        // would be indexed and skip when it matches.
        var hasher = Hasher()
        for contact in contacts where !contact.isUnidentified {
            hasher.combine(contact.publicKeyPrefix)
            hasher.combine(displayName(for: contact))
            hasher.combine(contact.type)
        }
        let fingerprint = hasher.finalize()
        guard fingerprint != spotlightFingerprint else { return }
        spotlightFingerprint = fingerprint

        indexContactsForSpotlightNow()
    }

    private func indexContactsForSpotlightNow() {
        // Replace the domain rather than adding to it. Items are indexed with
        // expirationDate = .distantFuture, so an entry for a contact that no
        // longer exists would otherwise stay searchable forever — including
        // every contact deleted before per-contact cleanup existed. Clearing
        // the domain first makes a full sync self-healing, with no migration.
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [Self.spotlightDomain])

        var items: [CSSearchableItem] = []
        for contact in contacts where !contact.isUnidentified {
            let attrs = CSSearchableItemAttributeSet(contentType: .contact)
            attrs.displayName = displayName(for: contact)
            attrs.contentDescription = "PommeCore \(contact.type == .repeater ? "repeater" : contact.type == .room ? "room server" : "contact")"
            let pubkeyHex = contact.publicKey.hexCompact
            let item = CSSearchableItem(
                uniqueIdentifier: "meshcore.contact.\(pubkeyHex)",
                domainIdentifier: Self.spotlightDomain,
                attributeSet: attrs
            )
            item.expirationDate = .distantFuture
            items.append(item)
        }
        CSSearchableIndex.default().indexSearchableItems(items)
    }

    /// Remove one contact from the Spotlight index.
    ///
    /// Indexed items are created with `expirationDate = .distantFuture`, so
    /// nothing expires them — a deleted contact stays searchable until it is
    /// explicitly deleted here.
    private func removeContactFromSpotlight(pubkeyHex: String) {
        CSSearchableIndex.default().deleteSearchableItems(
            withIdentifiers: ["meshcore.contact.\(pubkeyHex)"]
        )
    }
    #else
    private func removeContactFromSpotlight(pubkeyHex: String) {}
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
                self?.loadMutedContactsFromiCloud()
                self?.loadBlockedFromiCloud()
            }
        }
    }

    // MARK: - Reset

    func reset() {
        contactSyncDebounceTask?.cancel()
        isSyncingContacts = false
        isIncrementalContactSync = false
        // Authority to sweep belongs to the connection that proved the list,
        // and does not survive it.
        hasCompletedFullContactSync = false
        // A pending write deliberately survives: reset() runs on every
        // disconnect, and a link that drops mid-burst is precisely when the
        // retry is needed. Clearing it here is how a profile import lost 4 of
        // 11 contact adds for good — the link dropped, reset() discarded the
        // outstanding work, and the reconnect sync had nothing to reconcile
        // against. It is stamped with the radio's key and dropped on the next
        // verification if that radio changed.
        lastContactsSync = 0
        incomingContacts = []
        pendingNewContacts = []
        contacts = []
        nicknames = [:]
        contactNotes = [:]
    }
}
