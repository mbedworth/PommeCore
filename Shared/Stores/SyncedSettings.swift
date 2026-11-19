//
//  SyncedSettings.swift
//  PommeCore
//
//  App settings synced across devices via iCloud key-value store.
//  Observes UserDefaults changes (from @AppStorage) and pushes to iCloud KVS.
//  When iCloud changes arrive, writes back to UserDefaults so @AppStorage picks them up.
//
//  Created by Michael P. Bedworth on 04/07/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import Foundation
import Combine
import MeshCoreKit   // DebugLogger, used by the RetiredDefaults sweep

/// Codable payload stored as a single blob in iCloud KVS under key "appSettings".
struct SyncedSettingsPayload: Codable {
    var appTheme: String
    var batteryChemistry: String
    var maxMessagesPerContact: Int
    var locationPrivacyRadius: Double
    var shareOnMeshMap: Bool
    var autoUpdateLocation: Bool
    var locationUpdateInterval: Int
    var contactSortByLastSeen: Bool
    var channelsFirst: Bool
    var autoRetry: Bool
    var autoResetPath: Bool
    /// `ContactStore.StaleScope` raw value. String rather than the enum so an
    /// unknown value from a newer build decodes to the safe default instead of
    /// failing the whole payload (rules 1 and 2).
    var staleCleanupScope: String
    var staleCleanupDays: Int
    /// Whether to show the transient notice when the radio drops its oldest
    /// contact to make room. The purge itself always happens; this is only
    /// whether we mention it.
    var notifyContactPurge: Bool
    var lastModified: Date
}

extension SyncedSettingsPayload {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appTheme = try c.decodeIfPresent(String.self, forKey: .appTheme) ?? "system"
        batteryChemistry = try c.decodeIfPresent(String.self, forKey: .batteryChemistry) ?? "liion"
        maxMessagesPerContact = try c.decodeIfPresent(Int.self, forKey: .maxMessagesPerContact) ?? 500
        locationPrivacyRadius = try c.decodeIfPresent(Double.self, forKey: .locationPrivacyRadius) ?? 0
        shareOnMeshMap = try c.decodeIfPresent(Bool.self, forKey: .shareOnMeshMap) ?? true
        autoUpdateLocation = try c.decodeIfPresent(Bool.self, forKey: .autoUpdateLocation) ?? false
        locationUpdateInterval = try c.decodeIfPresent(Int.self, forKey: .locationUpdateInterval) ?? 300
        contactSortByLastSeen = try c.decodeIfPresent(Bool.self, forKey: .contactSortByLastSeen) ?? false
        channelsFirst = try c.decodeIfPresent(Bool.self, forKey: .channelsFirst) ?? false
        autoRetry = try c.decodeIfPresent(Bool.self, forKey: .autoRetry) ?? true
        autoResetPath = try c.decodeIfPresent(Bool.self, forKey: .autoResetPath) ?? true
        // Off by default: the sweep proposes removals from the radio, and that
        // is the user's call to switch on, not ours to assume.
        staleCleanupScope = try c.decodeIfPresent(String.self, forKey: .staleCleanupScope) ?? "off"
        staleCleanupDays = try c.decodeIfPresent(Int.self, forKey: .staleCleanupDays) ?? 30
        // On by default: a contact disappearing without explanation is worse
        // than a brief banner. It is coalesced and non-blocking, and anyone who
        // finds it noise can switch it off.
        notifyContactPurge = try c.decodeIfPresent(Bool.self, forKey: .notifyContactPurge) ?? true
        lastModified = try c.decodeIfPresent(Date.self, forKey: .lastModified) ?? Date()
    }
}

@MainActor
final class SyncedSettings {
    static let shared = SyncedSettings()

    private let iCloudStore = NSUbiquitousKeyValueStore.default
    private let defaults = UserDefaults.standard
    private static let kvsKey = "appSettings"

    /// Keys synced to iCloud. Must match SyncedSettingsPayload fields.
    private static let syncedKeys: [String] = [
        "appTheme", "batteryChemistry", "maxMessagesPerContact",
        "locationPrivacyRadius", "shareOnMeshMap", "autoUpdateLocation",
        "locationUpdateInterval", "contactSortByLastSeen", "channelsFirst",
        "autoRetry", "autoResetPath",
        "staleCleanupScope", "staleCleanupDays", "notifyContactPurge"
    ]

    private var isApplyingCloud = false
    private var cancellables = Set<AnyCancellable>()
    private var pushDebounceTask: Task<Void, Never>?

    // MARK: - Init

    private init() {
        migrateIfNeeded()
        observeUserDefaults()
        observeiCloudChanges()
    }

    // MARK: - Migration (first launch after update)

    private func migrateIfNeeded() {
        guard !defaults.bool(forKey: "settingsSyncMigrated") else {
            if iCloudSyncEnabled { applyCloudValues() }
            return
        }
        pushToCloud()
        defaults.set(true, forKey: "settingsSyncMigrated")
    }

    // MARK: - Observe UserDefaults (@AppStorage writes here)

    private func observeUserDefaults() {
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.isApplyingCloud else { return }
                self.schedulePush()
            }
            .store(in: &cancellables)
    }

    private func schedulePush() {
        pushDebounceTask?.cancel()
        pushDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s debounce
            guard !Task.isCancelled else { return }
            self.pushToCloud()
        }
    }

    // MARK: - Observe iCloud Changes

    private func observeiCloudChanges() {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: iCloudStore, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard iCloudSyncEnabled else { return }
                self?.applyCloudValues()
            }
        }
    }

    // MARK: - Cloud → Local

    private func applyCloudValues() {
        guard let payload = iCloudStore.loadCodable(SyncedSettingsPayload.self, forKey: Self.kvsKey) else { return }

        isApplyingCloud = true
        defer { isApplyingCloud = false }

        setIfDifferent("appTheme", payload.appTheme)
        setIfDifferent("batteryChemistry", payload.batteryChemistry)
        setIntIfDifferent("maxMessagesPerContact", payload.maxMessagesPerContact)
        setDoubleIfDifferent("locationPrivacyRadius", payload.locationPrivacyRadius)
        setBoolIfDifferent("shareOnMeshMap", payload.shareOnMeshMap)
        setBoolIfDifferent("autoUpdateLocation", payload.autoUpdateLocation)
        setIntIfDifferent("locationUpdateInterval", payload.locationUpdateInterval)
        setBoolIfDifferent("contactSortByLastSeen", payload.contactSortByLastSeen)
        setBoolIfDifferent("channelsFirst", payload.channelsFirst)
        setBoolIfDifferent("autoRetry", payload.autoRetry)
        setBoolIfDifferent("autoResetPath", payload.autoResetPath)
        setIfDifferent("staleCleanupScope", payload.staleCleanupScope)
        setIntIfDifferent("staleCleanupDays", payload.staleCleanupDays)
        setBoolIfDifferent("notifyContactPurge", payload.notifyContactPurge)
    }

    // MARK: - Local → Cloud

    private func pushToCloud() {
        guard iCloudSyncEnabled else { return }
        let payload = SyncedSettingsPayload(
            appTheme: defaults.string(forKey: "appTheme") ?? "system",
            batteryChemistry: defaults.string(forKey: "batteryChemistry") ?? "lipo",
            maxMessagesPerContact: defaults.object(forKey: "maxMessagesPerContact") != nil
                ? defaults.integer(forKey: "maxMessagesPerContact") : 500,
            locationPrivacyRadius: defaults.double(forKey: "locationPrivacyRadius"),
            shareOnMeshMap: defaults.bool(forKey: "shareOnMeshMap"),
            autoUpdateLocation: defaults.bool(forKey: "autoUpdateLocation"),
            locationUpdateInterval: defaults.object(forKey: "locationUpdateInterval") != nil
                ? defaults.integer(forKey: "locationUpdateInterval") : 900,
            contactSortByLastSeen: defaults.object(forKey: "contactSortByLastSeen") != nil
                ? defaults.bool(forKey: "contactSortByLastSeen") : true,
            channelsFirst: defaults.bool(forKey: "channelsFirst"),
            autoRetry: defaults.bool(forKey: "autoRetry"),
            autoResetPath: defaults.bool(forKey: "autoResetPath"),
            staleCleanupScope: defaults.string(forKey: "staleCleanupScope") ?? "off",
            staleCleanupDays: defaults.object(forKey: "staleCleanupDays") != nil
                ? defaults.integer(forKey: "staleCleanupDays") : 30,
            // Absent means never set, which is on — matching the decoder's
            // default. `bool(forKey:)` alone would read a missing key as false
            // and silently switch the notice off for everyone on first sync.
            notifyContactPurge: defaults.object(forKey: "notifyContactPurge") != nil
                ? defaults.bool(forKey: "notifyContactPurge") : true,
            lastModified: Date()
        )
        iCloudStore.saveCodable(payload, forKey: Self.kvsKey)
    }

    // MARK: - Helpers (only write to UserDefaults if value actually changed)

    private func setIfDifferent(_ key: String, _ value: String) {
        if defaults.string(forKey: key) != value {
            defaults.set(value, forKey: key)
        }
    }

    private func setIntIfDifferent(_ key: String, _ value: Int) {
        if defaults.integer(forKey: key) != value {
            defaults.set(value, forKey: key)
        }
    }

    private func setDoubleIfDifferent(_ key: String, _ value: Double) {
        if defaults.double(forKey: key) != value {
            defaults.set(value, forKey: key)
        }
    }

    private func setBoolIfDifferent(_ key: String, _ value: Bool) {
        if defaults.bool(forKey: key) != value {
            defaults.set(value, forKey: key)
        }
    }
}

// MARK: - Retired and renamed defaults keys

/// Every `UserDefaults` key this app has stopped using, and what became of it.
///
/// **This exists because a rename lost real user settings and nobody noticed
/// for eight months.** `9cf94d7` (March 2026) moved the notification toggles
/// out of `@AppStorage` in `UserDefaults` and into `NotificationPreferences`
/// in the iCloud key-value store, changing both the store *and* the key name
/// in one step — `notifyDirectMessages` became `notify.direct`. Nothing read
/// the old name afterwards, and the new reader treats an absent key as *on*:
///
///     notifyDirect = store.object(forKey: "notify.direct") == nil
///                  ? true : store.bool(forKey: "notify.direct")
///
/// So every user who had switched a notification **off** before that update
/// had it switched back **on**, silently, and their old value has been sitting
/// in `UserDefaults` ever since with nothing to read it. There was no error,
/// no warning, and no check — a renamed key is indistinguishable from a key
/// that was never set, which is precisely why a registry has to be written
/// down rather than remembered.
///
/// **Three cases, and only one of them is "delete the key":**
///
///   * **Renamed** — the setting still exists under a new name or in a new
///     store. Adopt the old value *only when the new location is empty*, then
///     clear the old one. See `sweepIfNeeded`.
///   * **Retired** — the feature is gone. Remove the key, not because the
///     bytes matter but because **the name must become safe to reuse.** A
///     future `expand.rooms` meaning something else would otherwise inherit a
///     stale value from an install that still carries one, and behave
///     differently on an upgrade than on a fresh install — the hardest kind of
///     bug to reproduce, since the developer's device never has the old value.
///   * **Retyped** — same name, new type. `UserDefaults` coerces `Bool`, `Int`
///     and `Double` through `NSNumber` without complaining, so this one fails
///     quietly in both directions. Treat it as a rename; never change a key's
///     type in place.
///
/// Settings in `SyncedSettingsPayload` need none of this: it is one blob with
/// a `decodeIfPresent` for every field, so adding and removing fields is
/// already free. This registry is for the keys that live outside it.
enum RetiredDefaults {

    /// Keys whose feature no longer exists. Removed once, then gone.
    ///
    /// The three `expand.*` keys held the collapsed state of the per-type
    /// contact sections, which #60 replaced with a single section and #94
    /// deleted outright. One section cannot be folded away, so there is
    /// nothing left to remember.
    ///
    /// `contactsExpanded` and `channelsExpanded` went at the same time and are
    /// deliberately **not** listed: both were `@State`, not `@AppStorage`, so
    /// they never persisted anything and have no key to retire.
    static let retired: [String] = [
        "expand.repeaters",     // retired v26.11.18 (#94)
        "expand.sensors",       // retired v26.11.18 (#94)
        "expand.rooms",         // retired v26.11.18 (#94)
    ]

    /// Settings that moved from `UserDefaults` to the iCloud key-value store
    /// and changed name on the way, in `9cf94d7`.
    ///
    /// `notifyContactPurge` looks like one of these and is **not** — it is a
    /// live `@AppStorage` key in `SettingsView+Sections.swift` and a field of
    /// `SyncedSettingsPayload`. Retiring it by shape rather than by checking
    /// would delete a working setting.
    static let renamedToCloud: [(legacy: String, current: String)] = [
        ("notifyDirectMessages",     "notify.direct"),
        ("notifyChannelMessages",    "notify.channel"),
        ("notifyRoomServerMessages", "notify.room"),
        ("notifyNewContacts",        "notify.newContacts"),
        ("notifyConnectionChanges",  "notify.connection"),
    ]

    /// Versioned so a later sweep can be added without re-running this one.
    private static let flagKey = "retiredDefaultsSwept.1"

    /// Adopt what can be recovered, clear what cannot, once per install.
    ///
    /// **A value already set in the new location always wins.** The recovery
    /// is for people whose preference was lost in March, not a reason to
    /// overwrite a choice made since: if `notify.direct` holds anything at
    /// all, the legacy key is discarded unread. Only an empty new location
    /// takes the old value.
    ///
    /// **Known race, accepted deliberately.** A key-value store read can
    /// return `nil` on first launch simply because iCloud has not delivered
    /// yet, so in principle this can adopt a legacy value over a cloud value
    /// that arrives moments later. Three things keep it small: it runs once
    /// per install; it touches nothing unless a legacy key is actually present
    /// (so only pre-March installs are ever in scope); and
    /// `NotificationPreferences` observes `didChangeExternallyNotification`,
    /// so a later cloud value is applied on arrival. The alternative — doing
    /// nothing — leaves the setting wrong forever, which is the status quo
    /// this fixes.
    ///
    /// Not gated on `iCloudSyncEnabled`: the reader in `NotificationPreferences`
    /// reads the key-value store unconditionally, so writing there is the only
    /// way the recovered value is ever seen.
    static func sweepIfNeeded(defaults: UserDefaults = .standard,
                              cloud: NSUbiquitousKeyValueStore = .default) {
        guard !defaults.bool(forKey: flagKey) else { return }

        var adopted: [String] = []
        for (legacy, current) in renamedToCloud {
            let old = defaults.object(forKey: legacy) as? Bool
            // Cleared whether or not it was adopted: either the value has been
            // carried across, or the new location already holds a better one.
            // Leaving it behind would only let a future key of the same name
            // pick it up.
            defaults.removeObject(forKey: legacy)
            guard let old, cloud.object(forKey: current) == nil else { continue }
            cloud.set(old, forKey: current)
            adopted.append(current)
        }
        if !adopted.isEmpty {
            cloud.synchronize()
            DebugLogger.shared.log(
                "DEFAULTS: recovered \(adopted.count) notification setting(s) "
                + "lost in the 9cf94d7 rename — \(adopted.joined(separator: ", "))",
                level: .info)
        }

        for key in retired {
            defaults.removeObject(forKey: key)
        }

        defaults.set(true, forKey: flagKey)
    }
}
