//
//  SettingsView.swift
//  MeshCoreApple
//
//  Device settings, radio config, privacy, iCloud, storage, and diagnostics.
//
//  Created by Michael P. Bedworth on 3/13/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import SwiftUI
import StoreKit
import LocalAuthentication
import CloudKit
import MeshCoreKit
#if !os(watchOS)
import CoreLocation
#endif

struct SettingsView: View {
    @Environment(DeviceConfig.self) private var deviceConfig
    @Environment(ConnectionManager.self) private var connectionManager
    @Environment(RemoteSessionManager.self) private var remoteSessionManager
    @Environment(MessageStoreManager.self) private var messageStoreManager
    @AppStorage("batteryChemistry") private var batteryChemistryRaw: String = BatteryChemistry.lipo.rawValue
    @AppStorage("appTheme") private var appTheme: String = AppTheme.system.rawValue
    @AppStorage("maxMessagesPerContact") private var maxMessagesPerContact: Int = 500
    @State private var statsExpanded = false
    @StateObject private var tipJar = TipJarManager()
    @State private var radioToDelete: String?
    @State private var showDeleteRadioConfirm = false
    @State private var radioToMigrate: String?
    @State private var showMigrateSheet = false
    @State private var showConnectionHelp = false
    @State private var showPurgeOptions = false
    @State private var showDebugLog = false
    @State private var showSupportersSheet = false
    @State private var supporterName = ""
    @StateObject private var supportersManager = SupportersManager()
    #if os(macOS) || targetEnvironment(macCatalyst)
    @State private var inspectorSheet: DeviceInfoSection.DeviceSheet?
    @State private var showInspector = false
    @State private var showTipJarSheet = false
    #else
    @State private var iosDeviceSheet: DeviceInfoSection.DeviceSheet?
    @State private var showTipJarSheet = false
    #endif
    @State private var showSetupWizard = false

    private var batteryChemistry: BatteryChemistry {
        BatteryChemistry(rawValue: batteryChemistryRaw) ?? .lipo
    }

    var body: some View {
        Group {
            if !isConnected {
                disconnectedView
            } else {
                settingsForm
            }
        }
        .navigationTitle("Settings")
        .alert("Join the Supporters Wall?", isPresented: $tipJar.showSupporterNamePrompt) {
            TextField("Display name", text: $supporterName)
            Button("Add My Name") {
                let name = supporterName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task {
                    _ = await supportersManager.addSupporter(name: name)
                }
            }
            Button("No Thanks", role: .cancel) {}
        } message: {
            Text("Thank you for your generous tip! Enter a display name to appear on the Supporters Wall, visible to all MeshCore users.")
        }
        .onAppear {
            if isConnected {
                connectionManager.refreshAllSettings()
            }
        }
    }

    private var isConnected: Bool {
        connectionManager.connectionState == .ready || connectionManager.connectionState == .connected
    }

    // MARK: - Disconnected State

    private var disconnectedView: some View {
        List {
            appearanceSection
            iCloudSection
            radioDataSection

            Section {
                VStack(spacing: 16) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 48))
                        .foregroundStyle(MeshTheme.textSecondary)
                    Text("No Device Connected")
                        .font(.headline)
                    Text("Connect to a MeshCore radio to view and change device settings.")
                        .font(.subheadline)
                        .foregroundStyle(MeshTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }

            tipJarSection
            aboutSection
        }
        .meshListStyle()
        .sheet(isPresented: $showTipJarSheet) {
            NavigationStack {
                TipJarView(manager: tipJar)
            }
            .meshTheme()
        }
        .sheet(isPresented: $showSupportersSheet) {
            NavigationStack {
                SupportersView()
            }
            .meshTheme()
        }
    }

    // MARK: - Settings Form

    private var settingsForm: some View {
        List {
            // 1. Appearance
            appearanceSection

            // 2. Tip Jar
            tipJarSection

            // 3. Connection
            connectionSection

            // 4. Device Info (BLE/WiFi/USB Binary only — USB CLI uses RemoteManagementView)
            #if os(macOS) || targetEnvironment(macCatalyst)
            if isConnected && !connectionManager.isUSBCLIMode {
                deviceInfoSection
            }
            #else
            if isConnected {
                deviceInfoSection
            }
            #endif

            // 5. Notifications
            notificationsSection
            messageSettingsSection

            // 7. Privacy & Security
            privacySection

            // 7. iCloud & Storage
            iCloudSection
            radioDataSection
            storageSection

            // 8. Advanced (collapsed)
            Section {
                DisclosureGroup("Advanced") {
                    if isConnected {
                        if !deviceConfig.customVars.isEmpty {
                            customVarsSection
                        }
                        statsSection
                    }
                    troubleshootingSection
                }
                .listRowBackground(MeshTheme.surface)
            } header: {
                sectionInfoHeader("", info: "Developer and diagnostic tools. Most users won\u{2019}t need these.")
            }

            // 9. About
            aboutSection
            if isConnected {
                dangerZoneSection
            }
        }
        .meshListStyle()
        #if !os(macOS) && !targetEnvironment(macCatalyst)
        // iOS: sheet anchored here — above the conditional DeviceInfoSection — so
        // structural changes inside DeviceInfoSection can't auto-dismiss the sheet.
        .sheet(item: $iosDeviceSheet) { sheet in
            NavigationStack {
                Group {
                    switch sheet {
                    case .name: NameEditorSheet()
                    case .radio: RadioSection().navigationTitle("Radio Settings")
                    case .txPower: TxPowerEditorSheet()
                    case .tuning: TuningEditorSheet()
                    case .gps: GPSEditorSheet()
                    case .battery: BatteryEditorSheet(batteryChemistryRaw: $batteryChemistryRaw)
                    case .firmware: FirmwareDetailSheet()
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { iosDeviceSheet = nil }
                    }
                }
            }
            .meshTheme()
        }
        // iOS: Tip Jar sheet anchored at List level — same reason as iosDeviceSheet above.
        .sheet(isPresented: $showTipJarSheet) {
            NavigationStack {
                TipJarView(manager: tipJar)
            }
            .meshTheme()
        }
        .sheet(isPresented: $showSupportersSheet) {
            NavigationStack {
                SupportersView()
            }
            .meshTheme()
        }
        .sheet(isPresented: $showSetupWizard) {
            NavigationStack {
                NodeSetupWizardView(
                                publicKeyHex: deviceConfig.publicKeyHex,
                                currentAdvertName: deviceConfig.advertName,
                                onApplyName: { name in connectionManager.setAdvertName(name) }
                            )
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showSetupWizard = false }
                        }
                    }
            }
            .meshTheme()
            .frame(minWidth: 360, minHeight: 500)
        }
        #endif
        #if os(macOS) || targetEnvironment(macCatalyst)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 40)
        }
        // macOS/Catalyst: inspector panel replaces broken .sheet on Catalyst
        .inspector(isPresented: $showInspector) {
            if let sheet = inspectorSheet {
                NavigationStack {
                    Group {
                        switch sheet {
                        case .name: NameEditorSheet()
                        case .radio: RadioSection().navigationTitle("Radio Settings")
                        case .txPower: TxPowerEditorSheet()
                        case .tuning: TuningEditorSheet()
                        case .gps: GPSEditorSheet()
                        case .battery: BatteryEditorSheet(batteryChemistryRaw: $batteryChemistryRaw)
                        case .firmware: FirmwareDetailSheet()
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                showInspector = false
                                inspectorSheet = nil
                            }
                        }
                    }
                }
                .meshTheme()
            }
        }
        .inspectorColumnWidth(min: 300, ideal: 400, max: 500)
        // macOS/Catalyst: Tip Jar sheet anchored at the List level (not on the row Button)
        // so List cell reuse/re-render on sheet dismiss can't corrupt navigation state.
        .sheet(isPresented: $showTipJarSheet) {
            NavigationStack {
                TipJarView(manager: tipJar)
            }
            .meshTheme()
        }
        .sheet(isPresented: $showSupportersSheet) {
            NavigationStack {
                SupportersView()
            }
            .meshTheme()
        }
        .sheet(isPresented: $showSetupWizard) {
            NavigationStack {
                NodeSetupWizardView(
                                publicKeyHex: deviceConfig.publicKeyHex,
                                currentAdvertName: deviceConfig.advertName,
                                onApplyName: { name in connectionManager.setAdvertName(name) }
                            )
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showSetupWizard = false }
                        }
                    }
            }
            .meshTheme()
            .frame(minWidth: 360, minHeight: 500)
        }
        #endif
        // macOS/Catalyst: refresh button lives in the NavigationSplitView toolbar.
        // iOS: add a settings-specific refresh button.
        #if !os(macOS) && !targetEnvironment(macCatalyst)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    connectionManager.refreshAllSettings()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(MeshTheme.accent)
                }
                .help("Refresh all settings")
            }
        }
        #endif
    }
}

// MARK: - iCloud Sync

private extension SettingsView {
    var iCloudSection: some View {
        Section {
            Toggle(isOn: iCloudSyncBinding) {
                Label("Sync to iCloud", systemImage: "icloud")
                    .foregroundStyle(MeshTheme.accent)
            }
            .tint(MeshTheme.accent)
            .listRowBackground(MeshTheme.surface)

            if iCloudSyncBinding.wrappedValue {
                let usage = iCloudKVSUsage()
                HStack {
                    Text("iCloud Storage")
                        .foregroundStyle(MeshTheme.textPrimary)
                    Spacer()
                    Text("\(usage.keys) keys, \(ByteCountFormatter.string(fromByteCount: Int64(usage.bytes), countStyle: .memory))")
                        .font(.caption)
                        .foregroundStyle(usage.bytes > 900_000 ? .red : usage.bytes > 700_000 ? .orange : MeshTheme.textSecondary)
                }
                .listRowBackground(MeshTheme.surface)
                if usage.bytes > 900_000 {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text("Approaching iCloud limit (1 MB). Consider deleting old radio data below.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .listRowBackground(MeshTheme.surface)
                }
            }
        } header: {
            sectionInfoHeader("iCloud", info: "Syncs nicknames, notes, channel secrets, login credentials, and recent messages between your Apple devices via iCloud. Data is encrypted by Apple in transit and at rest. Messages are stored per radio \u{2014} switching radios keeps data separate.")
        }
    }

    private func iCloudKVSUsage() -> (keys: Int, bytes: Int) {
        let store = NSUbiquitousKeyValueStore.default
        let dict = store.dictionaryRepresentation
        var totalBytes = 0
        for (key, value) in dict {
            totalBytes += key.utf8.count
            if let data = value as? Data { totalBytes += data.count }
            else if let string = value as? String { totalBytes += string.utf8.count }
            else if let array = value as? [Any] { totalBytes += MemoryLayout<Int>.size * array.count }
            else { totalBytes += 8 }
        }
        return (dict.count, totalBytes)
    }

    private var iCloudSyncBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.object(forKey: "iCloudSyncEnabled") == nil ? true : UserDefaults.standard.bool(forKey: "iCloudSyncEnabled") },
            set: { UserDefaults.standard.set($0, forKey: "iCloudSyncEnabled") }
        )
    }

    var radioDataSection: some View {
        RadioDataSection(radioToDelete: $radioToDelete, showDeleteRadioConfirm: $showDeleteRadioConfirm, radioToMigrate: $radioToMigrate, showMigrateSheet: $showMigrateSheet)
    }
}

struct RadioDataSection: View {
    @Environment(DeviceConfig.self) private var deviceConfig
    @Binding var radioToDelete: String?
    @Binding var showDeleteRadioConfirm: Bool
    @Binding var radioToMigrate: String?
    @Binding var showMigrateSheet: Bool

    private var currentRadioPrefix: String? {
        let hex = deviceConfig.publicKeyHex
        return hex.isEmpty ? nil : String(hex.prefix(12))
    }

    private var knownRadios: [String] {
        var prefixes = Set<String>()

        // Discover from iCloud message keys
        let store = NSUbiquitousKeyValueStore.default
        let allKeys = store.dictionaryRepresentation.keys
        for key in allKeys where key.hasPrefix("msg.") {
            let parts = key.dropFirst(4) // remove "msg."
            if let dot = parts.firstIndex(of: ".") {
                prefixes.insert(String(parts[parts.startIndex..<dot]))
            }
        }

        // Discover from local per-radio message subdirectories
        for prefix in MessageStore.knownRadioPrefixes() {
            prefixes.insert(prefix)
        }

        return prefixes.sorted()
    }

    var body: some View {
        if !knownRadios.isEmpty {
            Section {
                ForEach(knownRadios, id: \.self) { radioPrefix in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Radio \(radioPrefix.prefix(8))...")
                                .font(.body)
                                .foregroundStyle(MeshTheme.textPrimary)
                            Text("\(messageCountForRadio(radioPrefix)) messages in iCloud")
                                .font(.caption)
                                .foregroundStyle(MeshTheme.textSecondary)
                        }
                        Spacer()
                        if radioPrefix == currentRadioPrefix {
                            Text("Connected")
                                .font(.caption)
                                .foregroundStyle(MeshTheme.connected)
                        }
                    }
                    .contentShape(Rectangle())
                    .listRowBackground(MeshTheme.surface)
                    .contextMenu {
                        if radioPrefix != currentRadioPrefix && currentRadioPrefix != nil {
                            Button {
                                radioToMigrate = radioPrefix
                                showMigrateSheet = true
                            } label: {
                                Label("Migrate to Current Radio", systemImage: "arrow.right.arrow.left")
                            }
                        }
                        Button(role: .destructive) {
                            radioToDelete = radioPrefix
                            showDeleteRadioConfirm = true
                        } label: {
                            Label("Delete All Data", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            radioToDelete = radioPrefix
                            showDeleteRadioConfirm = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } header: {
                SectionInfoHeader(title: "Radio Data", info: "Each radio stores messages separately. If you replace a radio, use \u{2018}Migrate\u{2019} to move history to your new device.")
            }
            .confirmationDialog("Delete Radio Data?", isPresented: $showDeleteRadioConfirm) {
                Button("Delete All Messages", role: .destructive) {
                    if let prefix = radioToDelete {
                        deleteRadioData(radioPrefix: prefix)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete all synced messages for this radio from iCloud and all your devices. This cannot be undone.")
            }
            .sheet(isPresented: $showMigrateSheet) {
                NavigationStack {
                    VStack(spacing: 16) {
                        Image(systemName: "arrow.right.arrow.left")
                            .font(.system(size: 48))
                            .foregroundStyle(MeshTheme.accent)
                        Text("Migrate Messages")
                            .font(.headline)
                        Text("Copy all message history from the old radio to your currently connected radio.")
                            .font(.subheadline)
                            .foregroundStyle(MeshTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button("Migrate") {
                            if let old = radioToMigrate, let current = currentRadioPrefix {
                                migrateRadioData(from: old, to: current)
                            }
                            showMigrateSheet = false
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(MeshTheme.interactiveGreen)
                    }
                    .padding()
                    .navigationTitle("Migrate Radio Data")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showMigrateSheet = false }
                        }
                    }
                }
            }
        }
    }

    private func messageCountForRadio(_ radioPrefix: String) -> Int {
        let store = NSUbiquitousKeyValueStore.default
        let allKeys = store.dictionaryRepresentation.keys
        return allKeys.filter { $0.hasPrefix("msg.\(radioPrefix).") }.count * 50 // approximate
    }

    private func deleteRadioData(radioPrefix: String) {
        let store = NSUbiquitousKeyValueStore.default
        let allKeys = store.dictionaryRepresentation.keys

        // Delete iCloud message keys, scoped drafts, lastRead, and channel notify keys
        let prefixes = ["msg.\(radioPrefix).", "draft.\(radioPrefix).", "lastRead.\(radioPrefix).", "channel.notify.\(radioPrefix)."]
        for key in allKeys {
            if prefixes.contains(where: { key.hasPrefix($0) }) {
                store.removeObject(forKey: key)
            }
        }
        store.synchronize()

        // Delete local per-radio message directory
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let radioDir = docs.appendingPathComponent("MeshCoreMessages/\(radioPrefix)", isDirectory: true)
        try? FileManager.default.removeItem(at: radioDir)
    }

    private func migrateRadioData(from oldPrefix: String, to newPrefix: String) {
        let store = NSUbiquitousKeyValueStore.default
        let allKeys = store.dictionaryRepresentation.keys

        // Migrate iCloud KVS keys: messages, drafts, lastRead, channel notify
        let kvsPrefixes = ["msg.", "draft.", "lastRead.", "channel.notify."]
        for kvsPrefix in kvsPrefixes {
            let oldFullPrefix = "\(kvsPrefix)\(oldPrefix)."
            for oldKey in allKeys where oldKey.hasPrefix(oldFullPrefix) {
                let suffix = String(oldKey.dropFirst(oldFullPrefix.count))
                let newKey = "\(kvsPrefix)\(newPrefix).\(suffix)"
                if kvsPrefix == "msg." {
                    if let data = store.data(forKey: oldKey) {
                        store.set(data, forKey: newKey)
                    }
                } else if let str = store.string(forKey: oldKey) {
                    store.set(str, forKey: newKey)
                } else {
                    let val = store.double(forKey: oldKey)
                    if val > 0 { store.set(val, forKey: newKey) }
                }
            }
        }
        store.synchronize()

        // Migrate local message files
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let oldDir = docs.appendingPathComponent("MeshCoreMessages/\(oldPrefix)", isDirectory: true)
        let newDir = docs.appendingPathComponent("MeshCoreMessages/\(newPrefix)", isDirectory: true)
        if FileManager.default.fileExists(atPath: oldDir.path) {
            try? FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
            if let files = try? FileManager.default.contentsOfDirectory(at: oldDir, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension == "json" {
                    let dest = newDir.appendingPathComponent(file.lastPathComponent)
                    try? FileManager.default.copyItem(at: file, to: dest)
                }
            }
        }
    }
}

// MARK: - Section 0: Appearance

private extension SettingsView {
    var appearanceSection: some View {
        Section {
            Picker("Theme", selection: $appTheme) {
                ForEach(AppTheme.allCases, id: \.rawValue) { theme in
                    Text(theme.rawValue).tag(theme.rawValue)
                }
            }
            .pickerStyle(.segmented)

            Toggle(isOn: AppStorage(wrappedValue: false, "channelsFirst").projectedValue) {
                Label("Channels First", systemImage: "arrow.up.arrow.down")
                    .foregroundStyle(MeshTheme.accent)
            }
            .tint(MeshTheme.accent)
            .listRowBackground(MeshTheme.surface)
        } header: {
            sectionInfoHeader("Appearance", info: "Choose how MeshCore looks. System follows your device\u{2019}s Dark Mode setting.")
        }
    }
}

// MARK: - Notifications

private extension SettingsView {
    var notificationsSection: some View {
        NotificationsSection()
    }
}

struct NotificationsSection: View {
    @ObservedObject private var prefs = NotificationPreferences.shared

    var body: some View {
        Section {
            Toggle(isOn: $prefs.notifyDirect) {
                Label("Direct Messages", systemImage: "bubble.left.fill")
                    .foregroundStyle(MeshTheme.accent)
            }
            .tint(MeshTheme.accent)
            .listRowBackground(MeshTheme.surface)

            Toggle(isOn: $prefs.notifyChannel) {
                Label("Channel Messages", systemImage: "number")
                    .foregroundStyle(MeshTheme.accent)
            }
            .tint(MeshTheme.accent)
            .listRowBackground(MeshTheme.surface)

            Toggle(isOn: $prefs.notifyRoom) {
                Label("Room Server Messages", systemImage: "server.rack")
                    .foregroundStyle(MeshTheme.accent)
            }
            .tint(MeshTheme.accent)
            .listRowBackground(MeshTheme.surface)

            Toggle(isOn: $prefs.notifyNewContacts) {
                Label("New Contacts Discovered", systemImage: "person.badge.plus")
                    .foregroundStyle(MeshTheme.accent)
            }
            .tint(MeshTheme.accent)
            .listRowBackground(MeshTheme.surface)

            Toggle(isOn: $prefs.notifyConnection) {
                Label("Connection Status", systemImage: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(MeshTheme.accent)
            }
            .tint(MeshTheme.accent)
            .listRowBackground(MeshTheme.surface)
        } header: {
            SectionInfoHeader(title: "Notifications", info: "Choose which events trigger notifications when the app is in the background.")
        }
    }
}

// MARK: - Message Settings

private extension SettingsView {
    var messageSettingsSection: some View {
        Section {
            Toggle(isOn: autoRetryBinding) {
                Label("Auto Retry", systemImage: "arrow.clockwise")
                    .foregroundStyle(MeshTheme.accent)
            }
            .tint(MeshTheme.accent)
            .listRowBackground(MeshTheme.surface)

            Toggle(isOn: autoResetPathBinding) {
                Label("Auto Reset Path", systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(MeshTheme.accent)
            }
            .tint(MeshTheme.accent)
            .listRowBackground(MeshTheme.surface)

        } header: {
            SectionInfoHeader(title: "Message Delivery", info: "Auto Retry resends failed direct messages up to 3 times. Auto Reset Path clears the cached route and resends as flood.")
        }
    }

    private var autoRetryBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: "autoRetry") },
            set: { UserDefaults.standard.set($0, forKey: "autoRetry") }
        )
    }

    private var autoResetPathBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: "autoResetPath") },
            set: { UserDefaults.standard.set($0, forKey: "autoResetPath") }
        )
    }

}

// MARK: - Section 1: Device Info

private extension SettingsView {
    var deviceInfoSection: some View {
        #if os(macOS) || targetEnvironment(macCatalyst)
        DeviceInfoSection(batteryChemistryRaw: $batteryChemistryRaw, showSetupWizard: $showSetupWizard, connectedDeviceName: connectionManager.connectedDeviceName, inspectorSheet: $inspectorSheet, showInspector: $showInspector)
        #else
        DeviceInfoSection(batteryChemistryRaw: $batteryChemistryRaw, showSetupWizard: $showSetupWizard, connectedDeviceName: connectionManager.connectedDeviceName, activeSheet: $iosDeviceSheet)
        #endif
    }

}

/// Device Info section.
/// macOS/Catalyst: rows set a binding that opens an inspector panel on the parent List.
/// iOS: .sheet(item:) with isolated @State.
/// DeviceConfig is @Observable via @Environment — SwiftUI tracks only the
/// specific properties read in body. No cascade from ViewModel changes.
struct DeviceInfoSection: View {
    @Environment(DeviceConfig.self) private var deviceConfig
    @Binding var batteryChemistryRaw: String
    @Binding var showSetupWizard: Bool
    var connectedDeviceName: String?
    #if os(macOS) || targetEnvironment(macCatalyst)
    /// Binding to parent SettingsView — drives the inspector panel content.
    @Binding var inspectorSheet: DeviceSheet?
    /// Binding to parent SettingsView — shows/hides the inspector panel.
    @Binding var showInspector: Bool
    #else
    /// Binding to parent SettingsView — state lives there so sheet survives DeviceInfoSection re-renders.
    @Binding var activeSheet: DeviceSheet?
    #endif

    private var config: DeviceConfig { deviceConfig }

    // MARK: - Row views (shared between platforms)

    private var nameRow: some View {
        HStack {
            Label("Name", systemImage: "textformat")
                .foregroundStyle(MeshTheme.accent)
            Spacer()
            Text(config.deviceName.isEmpty ? (connectedDeviceName ?? "\u{2014}") : config.deviceName)
                .foregroundStyle(MeshTheme.textSecondary)
        }
        .contentShape(Rectangle())
    }

    private var wizardRow: some View {
        HStack {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(MeshTheme.accent)
                .frame(width: 24)
            Text("Name Wizard")
                .foregroundStyle(MeshTheme.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(MeshTheme.textSecondary)
        }
        .contentShape(Rectangle())
    }

    private var radioRow: some View {
        let freqStr = formatFrequency(Double(config.radioFrequency))
        let bwKHz = String(format: "%.1f", Double(config.radioBandwidth) / 1000.0)
        let presetName = detectPreset()
        return HStack {
            Label("Radio", systemImage: "antenna.radiowaves.left.and.right")
                .foregroundStyle(MeshTheme.accent)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(freqStr) \u{2022} \(bwKHz)kHz \u{2022} SF\(config.radioSpreadingFactor) CR\(config.radioCodingRate)")
                    .font(.caption)
                    .foregroundStyle(MeshTheme.textSecondary)
                Text(presetName ?? "Custom")
                    .font(.caption2)
                    .foregroundStyle(presetName != nil ? .green : .orange)
            }
        }
        .contentShape(Rectangle())
    }

    private var tuningRow: some View {
        HStack {
            Label("Tuning", systemImage: "tuningfork")
                .foregroundStyle(MeshTheme.accent)
            Spacer()
            Text("RX \(String(format: "%.1f", config.rxDelaySeconds))s \u{2022} Air \(String(format: "%.1f", config.airtimeMultiplier))x")
                .font(.caption)
                .foregroundStyle(MeshTheme.textSecondary)
        }
        .contentShape(Rectangle())
    }

    private var gpsRow: some View {
        HStack {
            Label("GPS", systemImage: "location.fill")
                .foregroundStyle(MeshTheme.accent)
            Spacer()
            if config.latitude != 0 || config.longitude != 0 {
                Text("\(String(format: "%.4f", config.latitude)), \(String(format: "%.4f", config.longitude))")
                    .font(.caption)
                    .foregroundStyle(MeshTheme.textSecondary)
            } else {
                Text("Not set")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .contentShape(Rectangle())
    }

    private var batteryRow: some View {
        HStack {
            Label("Battery", systemImage: "battery.50percent")
                .foregroundStyle(MeshTheme.accent)
            Spacer()
            let battV = String(format: "%.2f", Double(config.batteryMillivolts) / 1000.0)
            let battPct = config.batteryPercent()
            Text(battPct > 0 ? "\(battV)V (\(battPct)%)" : "\(battV)V")
                .foregroundStyle(MeshTheme.textSecondary)
        }
        .contentShape(Rectangle())
    }

    private var firmwareRow: some View {
        HStack {
            Label("Firmware", systemImage: "cpu")
                .foregroundStyle(MeshTheme.accent)
            Spacer()
            Text(config.semanticVersion.isEmpty ? "v\(config.firmwareVersion)" : config.semanticVersion)
                .foregroundStyle(MeshTheme.textSecondary)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Body

    // DeviceSheet enum shared between platforms
    enum DeviceSheet: Identifiable {
        case radio, txPower, tuning, name, gps, battery, firmware
        var id: String { String(describing: self) }
    }

    #if os(macOS) || targetEnvironment(macCatalyst)
    private func openInspector(_ sheet: DeviceSheet) {
        inspectorSheet = sheet
        showInspector = true
    }
    #endif

    var body: some View {
        Section {
            #if os(macOS) || targetEnvironment(macCatalyst)
            Button { openInspector(.name) } label: { nameRow }
                .buttonStyle(.plain).listRowBackground(MeshTheme.surface)
            Button { showSetupWizard = true } label: { wizardRow }
                .buttonStyle(.plain).listRowBackground(MeshTheme.surface)
            if config.radioFrequency > 0 {
                Button { openInspector(.radio) } label: { radioRow }
                    .buttonStyle(.plain).listRowBackground(MeshTheme.surface)
                Button { openInspector(.tuning) } label: { tuningRow }
                    .buttonStyle(.plain).listRowBackground(MeshTheme.surface)
            }
            Button { openInspector(.gps) } label: { gpsRow }
                .buttonStyle(.plain).listRowBackground(MeshTheme.surface)
            Button { openInspector(.battery) } label: { batteryRow }
                .buttonStyle(.plain).listRowBackground(MeshTheme.surface)
            Button { openInspector(.firmware) } label: { firmwareRow }
                .buttonStyle(.plain).listRowBackground(MeshTheme.surface)
            #else
            iOSDeviceRows
            #endif
        } header: {
            SectionInfoHeader(title: "Device", info: "Tap any row to view or change that setting on your connected radio.")
        }
    }

    // MARK: - iOS sheet-based rows

    #if !os(macOS) && !targetEnvironment(macCatalyst)
    private var iOSDeviceRows: some View {
        Group {
            Button { activeSheet = .name } label: { nameRow }
                .buttonStyle(.plain).listRowBackground(MeshTheme.surface)
            Button { showSetupWizard = true } label: { wizardRow }
                .buttonStyle(.plain).listRowBackground(MeshTheme.surface)
            if config.radioFrequency > 0 {
                Button { activeSheet = .radio } label: { radioRow }
                    .buttonStyle(.plain).listRowBackground(MeshTheme.surface)
                Button { activeSheet = .tuning } label: { tuningRow }
                    .buttonStyle(.plain).listRowBackground(MeshTheme.surface)
            }
            Button { activeSheet = .gps } label: { gpsRow }
                .buttonStyle(.plain).listRowBackground(MeshTheme.surface)
            Button { activeSheet = .battery } label: { batteryRow }
                .buttonStyle(.plain).listRowBackground(MeshTheme.surface)
            Button { activeSheet = .firmware } label: { firmwareRow }
                .buttonStyle(.plain).listRowBackground(MeshTheme.surface)
        }
        // Sheet now lives in SettingsView (above this view) to survive structural changes here.
    }
    #endif

    private func detectPreset() -> String? {
        let freqKHz = Double(config.radioFrequency)
        let bwKHz = Double(config.radioBandwidth) / 1000.0
        let sf = config.radioSpreadingFactor
        let cr = config.radioCodingRate
        return radioPresets.first { p in
            abs(p.frequencyKHz - freqKHz) < 2.0 &&
            abs(p.bandwidth - bwKHz) < 0.5 &&
            p.spreadingFactor == sf &&
            p.codingRate == cr
        }?.name
    }
}

private extension SettingsView {
    var batteryChemistryPicker: some View {
        HStack {
            Image(systemName: "bolt.batteryblock")
                .foregroundStyle(MeshTheme.accent)
                .frame(width: 24)
            Picker("Battery Type", selection: $batteryChemistryRaw) {
                ForEach(BatteryChemistry.allCases) { chem in
                    Text(chem.displayName).tag(chem.rawValue)
                }
            }
            .foregroundStyle(MeshTheme.accent)
            .tint(MeshTheme.accent)
            .onChange(of: batteryChemistryRaw) {
                deviceConfig.resetBatteryCalibration()
            }
        }
        .listRowBackground(MeshTheme.surface)
    }

    var statsBatteryDisplay: String {
        guard config.statsBatteryMV != 0 else { return "\u{2014}" }
        let mv = Int(config.statsBatteryMV)
        if let cal = deviceConfig.batteryCalibration {
            let correctedMV = Int(Double(mv) * cal.correctionFactor)
            let v = Double(correctedMV) / 1000.0
            let pct = batteryChemistry.profile.percentage(forMillivolts: correctedMV)
            return "\(String(format: "%.2fV", v)) (\(pct)%)"
        }
        let v = Double(mv) / 1000.0
        let pct = batteryChemistry.profile.percentage(forMillivolts: mv)
        return "\(String(format: "%.2fV", v)) (\(pct)%)"
    }

    // Fix #11: Public key with Copy button
    var publicKeyRow: some View {
        HStack {
            Image(systemName: "key")
                .foregroundStyle(MeshTheme.accent)
                .frame(width: 24)
            Text("Public Key")
                .foregroundStyle(MeshTheme.accent)
            Spacer()
            Text(String(config.publicKeyHex.prefix(16)) + "...")
                .foregroundStyle(MeshTheme.textPrimary)
                .font(.caption)
            Button {
                copyToClipboard(config.publicKeyHex)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(MeshTheme.accent)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
        .listRowBackground(MeshTheme.surface)
    }

    var correctedBatteryPercent: Int {
        if let cal = deviceConfig.batteryCalibration {
            let correctedMV = cal.correctedMillivolts(config.batteryMillivolts)
            return batteryChemistry.profile.percentage(forMillivolts: correctedMV)
        }
        return config.batteryPercent(chemistry: batteryChemistry)
    }

    var correctedBatteryVoltage: Double {
        if let cal = deviceConfig.batteryCalibration {
            return cal.correctedVoltage(config.batteryVoltage)
        }
        return config.batteryVoltage
    }

    var batteryRow: some View {
        HStack {
            Image(systemName: batteryIconName)
                .foregroundStyle(batteryColor)
                .frame(width: 24)
            Text("Battery")
                .foregroundStyle(MeshTheme.accent)
            Spacer()
            if config.batteryMillivolts > 0 {
                Text("\(String(format: "%.2fV", correctedBatteryVoltage)) (\(correctedBatteryPercent)%)")
                    .foregroundStyle(MeshTheme.textPrimary)
            } else {
                Text("\u{2014}")
                    .foregroundStyle(MeshTheme.textSecondary)
            }
        }
        .listRowBackground(MeshTheme.surface)
    }

    var batteryCalibrationsRows: some View {
        Group {
            if let cal = deviceConfig.batteryCalibration, config.batteryMillivolts > 0 {
                HStack {
                    Image(systemName: "tuningfork")
                        .foregroundStyle(MeshTheme.accent)
                        .frame(width: 24)
                    Text("Raw Voltage")
                        .foregroundStyle(MeshTheme.accent)
                    Spacer()
                    Text(String(format: "%.2fV", config.batteryVoltage))
                        .foregroundStyle(MeshTheme.textSecondary)
                    Text(String(format: "(\u{00D7}%.3f)", cal.correctionFactor))
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                }
                .listRowBackground(MeshTheme.surface)

                Button {
                    deviceConfig.resetBatteryCalibration()
                } label: {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                            .foregroundStyle(MeshTheme.accent)
                            .frame(width: 24)
                        Text("Reset Calibration")
                            .foregroundStyle(MeshTheme.accent)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(MeshTheme.surface)
            }
        }
    }

    var batteryIconName: String {
        let pct = correctedBatteryPercent
        if pct > 75 { return "battery.100" }
        if pct > 50 { return "battery.75" }
        if pct > 25 { return "battery.50" }
        if pct > 0 { return "battery.25" }
        return "battery.0"
    }

    var batteryColor: Color {
        let pct = correctedBatteryPercent
        if pct > 50 { return .green }
        if pct > 20 { return .yellow }
        return .red
    }
}

// MARK: - Section 2: Connection

private extension SettingsView {
    var connectionSection: some View {
        Section {
            HStack {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(statusColor)
                    .shadow(color: statusColor.opacity(0.5), radius: 3)
                Text("Status")
                    .foregroundStyle(MeshTheme.accent)
                Spacer()
                Text(connectionLabel)
                    .foregroundStyle(MeshTheme.textPrimary)
            }
            .listRowBackground(MeshTheme.surface)

            if connectionManager.connectionState != .disconnected {
                Button(role: .destructive) {
                    #if os(macOS) || targetEnvironment(macCatalyst)
                    if connectionManager.usbManager.isConnected {
                        connectionManager.disconnectUSB()
                    } else if connectionManager.wifiManager.isConnected {
                        connectionManager.disconnectWiFi()
                    } else {
                        connectionManager.disconnect()
                    }
                    #else
                    connectionManager.disconnect()
                    #endif
                } label: {
                    HStack {
                        Image(systemName: "xmark.circle")
                        Text("Disconnect")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(MeshTheme.surface)
            }
        } header: {
            sectionInfoHeader("Connection", info: "MeshCore supports Bluetooth, WiFi, and USB Serial connections to your radio.")
        }
    }

    var statusColor: Color {
        switch connectionManager.connectionState {
        case .ready: MeshTheme.connected
        case .connected, .connecting: MeshTheme.connecting
        case .scanning: MeshTheme.scanning
        case .disconnected: MeshTheme.disconnected
        }
    }

    var connectionLabel: String {
        switch connectionManager.connectionState {
        case .ready: "Ready"
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .scanning: "Scanning"
        case .disconnected: "Disconnected"
        }
    }
}


// MARK: - Section 4: Radio Configuration (Fixes #3, #4, #5, #6)


/// Standard LoRa bandwidths in kHz
private let loraBandwidths: [Double] = [7.8, 10.4, 15.6, 20.8, 31.25, 41.7, 62.5, 125, 250, 500]

// RadioPreset, RadioPresetPicker, and radioPresets are in Shared/Models/RadioPreset.swift

struct RadioSection: View {

    @Environment(DeviceConfig.self) private var deviceConfig
    @Environment(ConnectionManager.self) private var connectionManager
    @Environment(RemoteSessionManager.self) private var remoteSessionManager
    @Environment(\.dismiss) private var dismiss
    @State private var freqMHz: String = ""
    @State private var selectedBW: Double = 250
    @State private var selectedSF: UInt8 = 12
    @State private var selectedCR: UInt8 = 5
    @State private var txPower: Double = 22
    @State private var maxTxPower: Double = 22
    @State private var deviceSelfType: UInt8 = 1
    @State private var showRepeatConfirm = false
    @State private var repeatMode = false
    @State private var initFreqKHz: Double = 0
    @State private var initBW: Double = 0
    @State private var initSF: UInt8 = 0
    @State private var initCR: UInt8 = 0

    var body: some View {
        Form {
        RadioPresetPicker(
            onApply: { preset in
                applyPreset(preset)
                let freq = UInt32(preset.frequencyKHz)
                let bw = UInt32(preset.bandwidth * 1000)
                connectionManager.setRadioParams(
                    frequency: freq, bandwidth: bw,
                    spreadingFactor: preset.spreadingFactor, codingRate: preset.codingRate,
                    repeatMode: repeatMode
                )
                // Radio params require reboot to take effect
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    connectionManager.sendCommand(MeshCoreProtocol.buildReboot(), label: "REBOOT")
                }
                dismiss()
            },
            currentFreqKHz: initFreqKHz,
            currentBW: initBW,
            currentSF: initSF,
            currentCR: initCR
        )

        Section {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(MeshTheme.accent)
                    .frame(width: 24)
                Text("Frequency (MHz)")
                    .foregroundStyle(MeshTheme.accent)
                Spacer()
                #if os(watchOS)
                TextField("MHz", text: $freqMHz)
                    .foregroundStyle(MeshTheme.textPrimary)
                    .frame(width: 80)
                #else
                TextField("MHz", text: $freqMHz)
                    .foregroundStyle(MeshTheme.textPrimary)
                    .textFieldStyle(MeshTextFieldStyle())
                    .frame(width: 110)
                #endif
            }
            .listRowBackground(MeshTheme.surface)

            // Fix #5: Bandwidth picker with standard LoRa values
            HStack {
                Image(systemName: "waveform")
                    .foregroundStyle(MeshTheme.accent)
                    .frame(width: 24)
                Picker("Bandwidth", selection: $selectedBW) {
                    ForEach(loraBandwidths, id: \.self) { bw in
                        Text(formatBW(bw)).tag(bw)
                    }
                }
                .foregroundStyle(MeshTheme.accent)
                .tint(MeshTheme.accent)
            }
            .listRowBackground(MeshTheme.surface)

            // Fix #4: Spreading Factor picker
            HStack {
                Image(systemName: "chart.bar")
                    .foregroundStyle(MeshTheme.accent)
                    .frame(width: 24)
                Picker("Spreading Factor", selection: $selectedSF) {
                    ForEach(Array(UInt8(7)...UInt8(12)), id: \.self) { val in
                        Text("SF\(val)").tag(val)
                    }
                }
                .foregroundStyle(MeshTheme.accent)
                .tint(MeshTheme.accent)
            }
            .listRowBackground(MeshTheme.surface)

            // Fix #3: Coding Rate picker
            HStack {
                Image(systemName: "shield")
                    .foregroundStyle(MeshTheme.accent)
                    .frame(width: 24)
                Picker("Coding Rate", selection: $selectedCR) {
                    Text("4/5").tag(UInt8(5))
                    Text("4/6").tag(UInt8(6))
                    Text("4/7").tag(UInt8(7))
                    Text("4/8").tag(UInt8(8))
                }
                .foregroundStyle(MeshTheme.accent)
                .tint(MeshTheme.accent)
            }
            .listRowBackground(MeshTheme.surface)

            VStack(alignment: .leading) {
                HStack {
                    Image(systemName: "bolt")
                        .foregroundStyle(MeshTheme.accent)
                        .frame(width: 24)
                    Text("TX Power: \(Int(txPower)) dBm")
                        .foregroundStyle(MeshTheme.accent)
                }
                Slider(value: $txPower, in: 2...max(maxTxPower, 2), step: 1)
                    .tint(MeshTheme.accent)
            }
            .listRowBackground(MeshTheme.surface)

            Toggle(isOn: Binding(
                get: { repeatMode },
                set: { newValue in
                    if newValue && deviceSelfType == 1 {
                        showRepeatConfirm = true
                    } else {
                        repeatMode = newValue
                    }
                }
            )) {
                HStack {
                    Image(systemName: "repeat")
                        .foregroundStyle(MeshTheme.accent)
                        .frame(width: 24)
                    Text("Repeat Mode")
                        .foregroundStyle(MeshTheme.accent)
                }
            }
            .tint(MeshTheme.accent)
            .listRowBackground(MeshTheme.surface)
            .alert("Enable Repeat Mode?", isPresented: $showRepeatConfirm) {
                Button("Enable") { repeatMode = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                if remoteSessionManager.allowedRepeatFreqRanges.isEmpty {
                    Text("Your companion radio will act as a portable repeater.\n\nThis is useful for camping, hiking, and search & rescue where repeater infrastructure doesn't exist.\n\nRepeat mode is restricted to allowed frequency ranges configured on the device.")
                } else {
                    let freqText = remoteSessionManager.allowedRepeatFreqRanges.map { range in
                        String(format: "%.1f\u{2013}%.1f MHz", Double(range.lowerHz) / 1_000_000, Double(range.upperHz) / 1_000_000)
                    }.joined(separator: "\n")
                    Text("Your companion radio will act as a portable repeater.\n\nAllowed frequency ranges:\n\(freqText)\n\nThis is useful for camping, hiking, and search & rescue where repeater infrastructure doesn't exist.")
                }
            }

            if !remoteSessionManager.allowedRepeatFreqRanges.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "waveform.badge.magnifyingglass")
                                .foregroundStyle(MeshTheme.accent)
                                .frame(width: 24)
                            Text("Allowed Repeat Frequencies")
                                .foregroundStyle(MeshTheme.accent)
                        }
                        ForEach(Array(remoteSessionManager.allowedRepeatFreqRanges.enumerated()), id: \.offset) { _, range in
                            Text("\(String(format: "%.3f", Double(range.lowerHz) / 1_000_000)) \u{2013} \(String(format: "%.3f", Double(range.upperHz) / 1_000_000)) MHz")
                                .font(.caption)
                                .foregroundStyle(MeshTheme.textPrimary)
                                .padding(.leading, 32)
                        }
                    }
                    .listRowBackground(MeshTheme.surface)
                }

                Button {
                    remoteSessionManager.requestAllowedRepeatFreq()
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(MeshTheme.accent)
                            .frame(width: 24)
                        Text("Query Repeat Frequencies")
                            .foregroundStyle(MeshTheme.accent)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(MeshTheme.surface)
        } header: {
            SectionInfoHeader(title: "Radio Configuration", info: "All radios on your mesh must use the same settings. SF (Spreading Factor): higher = longer range, slower. CR (Coding Rate): higher = more error correction. BW (Bandwidth): lower = longer range. Changes require reboot.")
        }
        } // end Form
        .onAppear { loadFromConfig() }
        .toolbar {
            #if targetEnvironment(macCatalyst)
            ToolbarItem(placement: .topBarTrailing) {
                Button("Apply & Reboot") { applyRadioAndReboot() }
            }
            #elseif os(macOS)
            ToolbarItem(placement: .primaryAction) {
                Button("Apply & Reboot") { applyRadioAndReboot() }
            }
            #else
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Apply & Reboot") { applyRadioAndReboot() }
            }
            #endif
        }
    }

    private func loadFromConfig() {
        let c = deviceConfig
        freqMHz = c.radioFrequency == 0 ? "" : String(format: "%.3f", c.frequencyMHz)
        selectedBW = nearestBW(c.bandwidthKHz)
        selectedSF = c.radioSpreadingFactor
        selectedCR = c.radioCodingRate
        txPower = Double(c.radioTXPower)
        maxTxPower = Double(c.maxTXPower)
        deviceSelfType = c.selfType
        repeatMode = c.repeatMode
        initFreqKHz = Double(c.radioFrequency)
        initBW = c.bandwidthKHz
        initSF = c.radioSpreadingFactor
        initCR = c.radioCodingRate
    }

    private func applyRadioAndReboot() {
        let freq = UInt32((Double(freqMHz) ?? 0) * 1000)
        let bw = UInt32(selectedBW * 1000)
        connectionManager.setRadioParams(frequency: freq, bandwidth: bw,
            spreadingFactor: selectedSF, codingRate: selectedCR,
            repeatMode: repeatMode)
        connectionManager.setRadioTXPower(UInt8(txPower))
        // Radio params require reboot to take effect
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            connectionManager.sendCommand(MeshCoreProtocol.buildReboot(), label: "REBOOT")
        }
        dismiss()
    }

    private func nearestBW(_ kHz: Double) -> Double {
        loraBandwidths.min(by: { abs($0 - kHz) < abs($1 - kHz) }) ?? 250
    }

    private func formatBW(_ bw: Double) -> String {
        if bw == bw.rounded() { return "\(Int(bw)) kHz" }
        return "\(bw) kHz"
    }

    private func applyPreset(_ preset: RadioPreset) {
        freqMHz = String(format: "%.3f", preset.frequencyKHz / 1000)
        selectedBW = nearestBW(preset.bandwidth)
        selectedSF = preset.spreadingFactor
        selectedCR = preset.codingRate
    }
}

// MARK: - Section 6: Privacy & Security (Fix #8: telemetry pickers)

private extension SettingsView {
    var privacySection: some View {
        PrivacySection()
    }
}

struct PrivacySection: View {

    @Environment(DeviceConfig.self) private var config
    @Environment(ConnectionManager.self) private var connectionManager
    @Environment(ContactStore.self) private var contactStore
    @State private var pinText: String = ""
    @State private var showBlockedContacts = false
    @AppStorage("locationPrivacyRadius") private var locationPrivacyRadius: Double = 0
    @AppStorage("shareOnMeshMap") private var shareOnMeshMap: Bool = false

    // Computed bindings that read from deviceConfig and auto-save on change
    private var manualAddBinding: Binding<Bool> {
        Binding(
            get: { config.manualAddContacts != 0 },
            set: { newValue in
                connectionManager.setOtherParams(
                    manualAddContacts: newValue ? 1 : 0,
                    telemetryBase: config.telemetryBase,
                    telemetryLocation: config.telemetryLocation,
                    advertLocPolicy: config.advertLocPolicy,
                    multiACK: config.multiACK
                )
            }
        )
    }

    private var telBaseBinding: Binding<UInt8> {
        Binding(
            get: { config.telemetryBase },
            set: { newValue in
                connectionManager.setOtherParams(
                    manualAddContacts: config.manualAddContacts,
                    telemetryBase: newValue,
                    telemetryLocation: config.telemetryLocation,
                    advertLocPolicy: config.advertLocPolicy,
                    multiACK: config.multiACK
                )
            }
        )
    }

    private var telLocBinding: Binding<UInt8> {
        Binding(
            get: { config.telemetryLocation },
            set: { newValue in
                connectionManager.setOtherParams(
                    manualAddContacts: config.manualAddContacts,
                    telemetryBase: config.telemetryBase,
                    telemetryLocation: newValue,
                    advertLocPolicy: config.advertLocPolicy,
                    multiACK: config.multiACK
                )
            }
        )
    }

    private var advertLocBinding: Binding<Bool> {
        Binding(
            get: { config.advertLocPolicy != 0 },
            set: { newValue in
                connectionManager.setOtherParams(
                    manualAddContacts: config.manualAddContacts,
                    telemetryBase: config.telemetryBase,
                    telemetryLocation: config.telemetryLocation,
                    advertLocPolicy: newValue ? 1 : 0,
                    multiACK: config.multiACK
                )
            }
        )
    }

    private var multiACKBinding: Binding<Bool> {
        Binding(
            get: { config.multiACK != 0 },
            set: { newValue in
                connectionManager.setOtherParams(
                    manualAddContacts: config.manualAddContacts,
                    telemetryBase: config.telemetryBase,
                    telemetryLocation: config.telemetryLocation,
                    advertLocPolicy: config.advertLocPolicy,
                    multiACK: newValue ? 1 : 0
                )
            }
        )
    }

    private func autoAddBinding(bit: UInt8) -> Binding<Bool> {
        Binding(
            get: { config.autoAddBitmask & bit != 0 },
            set: { enabled in
                var bm = config.autoAddBitmask
                if enabled { bm |= bit } else { bm &= ~bit }
                connectionManager.setAutoAddConfig(bitmask: bm)
            }
        )
    }

    var body: some View {
        Section {
            Toggle(isOn: manualAddBinding) {
                HStack {
                    Image(systemName: "person.badge.plus")
                        .foregroundStyle(MeshTheme.accent)
                        .frame(width: 24)
                    Text("Manual Add Contacts")
                        .foregroundStyle(MeshTheme.accent)
                }
            }
            .tint(MeshTheme.accent)
            .listRowBackground(MeshTheme.surface)

            if config.manualAddContacts == 0 {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        Text("Auto-Add Contact Types")
                            .font(.caption)
                            .foregroundStyle(MeshTheme.textSecondary)
                        InfoButton(text: "Chat = people, Repeaters extend range, Room Servers host group chats, Sensors report data.")
                    }
                    Toggle("Chat Users", isOn: autoAddBinding(bit: 0x01))
                        .tint(MeshTheme.accent)
                    Toggle("Repeaters", isOn: autoAddBinding(bit: 0x02))
                        .tint(MeshTheme.accent)
                    Toggle("Room Servers", isOn: autoAddBinding(bit: 0x04))
                        .tint(MeshTheme.accent)
                    Toggle("Sensors", isOn: autoAddBinding(bit: 0x08))
                        .tint(MeshTheme.accent)
                }
                .listRowBackground(MeshTheme.surface)
            }

            HStack {
                Image(systemName: "battery.100")
                    .foregroundStyle(MeshTheme.accent)
                    .frame(width: 24)
                Picker("Telemetry Requests", selection: telBaseBinding) {
                    Text("Deny").tag(UInt8(0))
                    Text("Per-Contact").tag(UInt8(1))
                    Text("Allow All").tag(UInt8(2))
                }
                .foregroundStyle(MeshTheme.accent)
                .tint(MeshTheme.accent)
            }
            .listRowBackground(MeshTheme.surface)

            HStack {
                Image(systemName: "location")
                    .foregroundStyle(MeshTheme.accent)
                    .frame(width: 24)
                Picker("Include Location", selection: telLocBinding) {
                    Text("Deny").tag(UInt8(0))
                    Text("Per-Contact").tag(UInt8(1))
                    Text("Allow All").tag(UInt8(2))
                }
                .foregroundStyle(MeshTheme.accent)
                .tint(MeshTheme.accent)
            }
            .listRowBackground(MeshTheme.surface)

            Toggle(isOn: advertLocBinding) {
                HStack {
                    Image(systemName: "location.slash")
                        .foregroundStyle(MeshTheme.accent)
                        .frame(width: 24)
                    Text("Share Location in Advert")
                        .foregroundStyle(MeshTheme.accent)
                }
            }
            .tint(MeshTheme.accent)
            .listRowBackground(MeshTheme.surface)

            #if !os(watchOS)
            Toggle(isOn: $shareOnMeshMap) {
                HStack {
                    Image(systemName: "globe")
                        .foregroundStyle(MeshTheme.accent)
                        .frame(width: 24)
                    HStack(spacing: 4) {
                        Text("Share Location on MeshCore Map")
                            .foregroundStyle(MeshTheme.accent)
                        InfoButton(text: "Uploads your node's signed advert packet to map.meshcore.dev so others can see your node on the internet map. Only uploads when you have a location set. Your GPS fudge factor is applied before uploading — the map receives the fuzzed position, not your exact location.")
                    }
                }
            }
            .tint(MeshTheme.accent)
            .listRowBackground(MeshTheme.surface)
            #endif

            Toggle(isOn: multiACKBinding) {
                HStack {
                    Image(systemName: "checkmark.message")
                        .foregroundStyle(MeshTheme.accent)
                        .frame(width: 24)
                    Text("Multi-ACK")
                        .foregroundStyle(MeshTheme.accent)
                }
            }
            .tint(MeshTheme.accent)
            .listRowBackground(MeshTheme.surface)

            HStack {
                Image(systemName: "location.slash.circle")
                    .foregroundStyle(MeshTheme.accent)
                    .frame(width: 24)
                Picker("Position Accuracy", selection: $locationPrivacyRadius) {
                    Text("Exact").tag(0.0)
                    Text("\u{00B1} 100m (~1 block)").tag(100.0)
                    Text("\u{00B1} 500m (~\u{00BC} mile)").tag(500.0)
                    Text("\u{00B1} 1km (~\u{00BD} mile)").tag(1000.0)
                    Text("\u{00B1} 5km (~3 miles)").tag(5000.0)
                }
                .foregroundStyle(MeshTheme.accent)
                .tint(MeshTheme.accent)
            }
            .listRowBackground(MeshTheme.surface)

            Toggle(isOn: appLockBinding) {
                Label("App Lock", systemImage: biometricIcon)
                    .foregroundStyle(MeshTheme.accent)
            }
            .tint(MeshTheme.accent)
            .listRowBackground(MeshTheme.surface)

            #if os(macOS) || targetEnvironment(macCatalyst)
            Button {
                showBlockedContacts = true
            } label: {
                HStack {
                    Label("Blocked Contacts", systemImage: "hand.raised")
                        .foregroundStyle(MeshTheme.accent)
                    Spacer()
                    if !contactStore.blockedContacts.isEmpty {
                        Text("\(contactStore.blockedContacts.count)")
                            .font(.caption)
                            .foregroundStyle(MeshTheme.textSecondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(MeshTheme.surface)
            #else
            NavigationLink {
                BlockedContactsView()
            } label: {
                HStack {
                    Label("Blocked Contacts", systemImage: "hand.raised")
                        .foregroundStyle(MeshTheme.accent)
                    Spacer()
                    if !contactStore.blockedContacts.isEmpty {
                        Text("\(contactStore.blockedContacts.count)")
                            .font(.caption)
                            .foregroundStyle(MeshTheme.textSecondary)
                    }
                }
            }
            .listRowBackground(MeshTheme.surface)
            #endif

        } header: {
            SectionInfoHeader(title: "Privacy & Security", info: "Controls what telemetry data is shared when requested. Per-Contact mode only shares with contacts that have telemetry permission set. Position Accuracy adds a random offset to your personal device location only. Repeater and room server locations are always shared at exact coordinates for accurate mesh routing. App Lock requires Face ID, Touch ID, or your device passcode to open MeshCore.")
        }

        // Per-contact telemetry permission picker
        if config.telemetryBase == 1 {
            Section {
                let chatContacts = contactStore.contacts.filter { $0.type == .chat }
                if chatContacts.isEmpty {
                    Text("No chat contacts available")
                        .foregroundStyle(MeshTheme.textSecondary)
                        .listRowBackground(MeshTheme.surface)
                } else {
                    ForEach(chatContacts) { contact in
                        Toggle(isOn: Binding(
                            get: { contact.allowTelemetry },
                            set: { enabled in
                                var newFlags = contact.flags
                                if enabled { newFlags |= 0x02 } else { newFlags &= ~0x02 }
                                contactStore.updateContactFlags(contact, newFlags: newFlags)
                            }
                        )) {
                            Text(contactStore.displayName(for: contact))
                                .foregroundStyle(MeshTheme.textPrimary)
                        }
                        .tint(MeshTheme.accent)
                        .listRowBackground(MeshTheme.surface)
                    }
                }
            } header: {
                Text("Contacts with Telemetry Permission")
                    .foregroundStyle(MeshTheme.textSecondary)
            } footer: {
                let count = contactStore.contacts.filter { $0.type == .chat && $0.allowTelemetry }.count
                Text("\(count) contact\(count == 1 ? "" : "s") can request your telemetry data.")
                    .font(.caption2)
            }
        }

        // Per-contact location permission picker
        if config.telemetryLocation == 1 {
            Section {
                let chatContacts = contactStore.contacts.filter { $0.type == .chat }
                if chatContacts.isEmpty {
                    Text("No chat contacts available")
                        .foregroundStyle(MeshTheme.textSecondary)
                        .listRowBackground(MeshTheme.surface)
                } else {
                    ForEach(chatContacts) { contact in
                        Toggle(isOn: Binding(
                            get: { contact.shareTelemetryLocation },
                            set: { enabled in
                                var newFlags = contact.flags
                                if enabled { newFlags |= 0x04 } else { newFlags &= ~0x04 }
                                contactStore.updateContactFlags(contact, newFlags: newFlags)
                            }
                        )) {
                            Text(contactStore.displayName(for: contact))
                                .foregroundStyle(MeshTheme.textPrimary)
                        }
                        .tint(MeshTheme.accent)
                        .listRowBackground(MeshTheme.surface)
                    }
                }
            } header: {
                Text("Contacts with Location Permission")
                    .foregroundStyle(MeshTheme.textSecondary)
            } footer: {
                let count = contactStore.contacts.filter { $0.type == .chat && $0.shareTelemetryLocation }.count
                Text("\(count) contact\(count == 1 ? "" : "s") will receive your location in telemetry.")
                    .font(.caption2)
            }
        }

        // BLE PIN — adaptive based on whether device has a screen
        Section {
            if config.blePIN == 0 {
                HStack {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(MeshTheme.accent)
                        .frame(width: 24)
                    Text("BLE PIN")
                        .foregroundStyle(MeshTheme.accent)
                    Spacer()
                    Text("Shown on device screen")
                        .foregroundStyle(MeshTheme.textPrimary)
                }
                .listRowBackground(MeshTheme.surface)
            } else {
                HStack {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(MeshTheme.accent)
                        .frame(width: 24)
                    Text("BLE PIN")
                        .foregroundStyle(MeshTheme.accent)
                    Spacer()
                    #if os(watchOS)
                    TextField("PIN", text: $pinText)
                        .foregroundStyle(MeshTheme.textPrimary)
                        .frame(width: 80)
                    #else
                    TextField("PIN", text: $pinText)
                        .foregroundStyle(MeshTheme.textPrimary)
                        .textFieldStyle(MeshTextFieldStyle())
                        .frame(width: 100)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    #endif
                }
                .listRowBackground(MeshTheme.surface)

                HStack {
                    Button {
                        connectionManager.setDevicePIN(1)
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            connectionManager.refreshAllSettings()
                        }
                    } label: {
                        Label("Randomize", systemImage: "dice")
                            .foregroundStyle(MeshTheme.accent)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        if let pin = UInt32(pinText), pin <= 999999 {
                            connectionManager.setDevicePIN(pin)
                        }
                    } label: {
                        Text("Apply")
                            .foregroundStyle(MeshTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(pinText.count > 6 || UInt32(pinText) == nil)
                }
                .listRowBackground(MeshTheme.surface)
            }
        } header: {
            SectionInfoHeader(
                title: "Bluetooth Security",
                info: config.blePIN == 0
                    ? "This device generates a random PIN each time it starts. Check the device screen for the current PIN when pairing."
                    : "Change the BLE PIN from the default (123456) for security. After changing, forget this device in Bluetooth settings and re-pair with the new PIN."
            )
        }
        .onAppear { pinText = String(config.blePIN) }
        .onChange(of: config.blePIN) { pinText = String(config.blePIN) }
        .onChange(of: locationPrivacyRadius) {
            MeshCoreViewModel.regenerateLocationFudge()
        }
        #if os(macOS) || targetEnvironment(macCatalyst)
        .sheet(isPresented: $showBlockedContacts) {
            NavigationStack {
                BlockedContactsView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showBlockedContacts = false }
                        }
                    }
            }
            .meshTheme()
            .frame(minWidth: 360, minHeight: 400)
        }
        #endif
    }

    private var appLockBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: "appLockEnabled") },
            set: { newValue in
                if newValue {
                    let context = LAContext()
                    var error: NSError?
                    if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
                        UserDefaults.standard.set(true, forKey: "appLockEnabled")
                    } else {
                        DebugLogger.shared.log("APP LOCK: cannot enable — no auth available: \(error?.localizedDescription ?? "unknown")", level: .error)
                    }
                } else {
                    UserDefaults.standard.set(false, forKey: "appLockEnabled")
                }
            }
        )
    }

    private var biometricIcon: String {
        #if os(iOS)
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        default: return "lock"
        }
        #else
        return "lock"
        #endif
    }
}

// MARK: - Section 8: Custom Variables

private extension SettingsView {
    var customVarsSection: some View {
        CustomVarsSection()
    }
}

struct CustomVarsSection: View {

    @Environment(DeviceConfig.self) private var deviceConfig
    @Environment(ConnectionManager.self) private var connectionManager
    @State private var newName: String = ""
    @State private var newValue: String = ""

    var body: some View {
        Section {
            ForEach(Array(deviceConfig.customVars.enumerated()), id: \.offset) { _, pair in
                HStack {
                    Text(pair.name)
                        .foregroundStyle(MeshTheme.textPrimary)
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    Text(pair.value)
                        .foregroundStyle(MeshTheme.textPrimary)
                        .font(.system(.body, design: .monospaced))
                }
                .listRowBackground(MeshTheme.surface)
            }

            HStack {
                #if os(watchOS)
                TextField("Name", text: $newName)
                    .foregroundStyle(MeshTheme.textPrimary)
                TextField("Value", text: $newValue)
                    .foregroundStyle(MeshTheme.textPrimary)
                #else
                TextField("Name", text: $newName)
                    .foregroundStyle(MeshTheme.textPrimary)
                    .textFieldStyle(MeshTextFieldStyle())
                TextField("Value", text: $newValue)
                    .foregroundStyle(MeshTheme.textPrimary)
                    .textFieldStyle(MeshTextFieldStyle())
                #endif
                Button {
                    guard !newName.isEmpty else { return }
                    connectionManager.setCustomVar(name: newName, value: newValue)
                    newName = ""
                    newValue = ""
                    Task {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        connectionManager.requestCustomVars()
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(MeshTheme.accent)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
            .listRowBackground(MeshTheme.surface)
        } header: {
            SectionInfoHeader(title: "Custom Variables", info: "Key-value pairs stored on the radio. Used for advanced configuration and firmware development.")
        }
    }
}

// MARK: - Section 9: Statistics (Fix #10: uptime with days)

private extension SettingsView {
    var statsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $statsExpanded) {
                // Core
                infoRow(icon: "battery.75", label: "Battery (stats)", value: statsBatteryDisplay)
                infoRow(icon: "clock.arrow.circlepath", label: "Uptime", value: config.statsUptime > 0 ? formatUptime(config.statsUptime) : "\u{2014}")
                infoRow(icon: "exclamationmark.triangle", label: "Error Flags", value: config.statsErrorFlags > 0 ? "0x\(String(format: "%04x", config.statsErrorFlags))" : "None")
                infoRow(icon: "tray", label: "Queue Length", value: "\(config.statsQueueLength)")

                // Radio
                infoRow(icon: "waveform.badge.minus", label: "Noise Floor", value: "\(config.statsNoiseFloor) dBm")
                infoRow(icon: "cellularbars", label: "Last RSSI", value: "\(config.statsLastRSSI) dBm")
                infoRow(icon: "antenna.radiowaves.left.and.right", label: "Last SNR", value: formatSNR(config.statsLastSNR))
                infoRow(icon: "arrow.up.circle", label: "TX Airtime", value: "\(config.statsTXAirtime) s")
                infoRow(icon: "arrow.down.circle", label: "RX Airtime", value: "\(config.statsRXAirtime) s")

                // Packets
                infoRow(icon: "arrow.down.doc", label: "Packets RX", value: "\(config.statsPacketsReceived)")
                infoRow(icon: "arrow.up.doc", label: "Packets TX", value: "\(config.statsPacketsSent)")
                infoRow(icon: "arrow.triangle.branch", label: "Sent Flood", value: "\(config.statsFloodCount)")
                infoRow(icon: "arrow.right", label: "Sent Direct", value: "\(config.statsDirectCount)")
                infoRow(icon: "arrow.down.left", label: "Recv Flood", value: "\(config.statsRecvFlood)")
                infoRow(icon: "arrow.down.right", label: "Recv Direct", value: "\(config.statsRecvDirect)")

                Button {
                    connectionManager.requestStats(subType: 0)
                    connectionManager.requestStats(subType: 1)
                    connectionManager.requestStats(subType: 2)
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(MeshTheme.accent)
                            .frame(width: 24)
                        Text("Refresh Stats")
                            .foregroundStyle(MeshTheme.accent)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } label: {
                Label("Statistics", systemImage: "chart.bar")
                    .foregroundStyle(MeshTheme.accent)
            }
            .listRowBackground(MeshTheme.surface)
        } header: {
            SectionInfoHeader(title: "", info: "Live radio diagnostics. Noise Floor is background signal level (lower is better). RSSI is received signal strength. SNR is signal-to-noise ratio (higher is better).")
        }
    }

    // Fix #10: Days in uptime
    func formatUptime(_ seconds: UInt32) -> String {
        let d = seconds / 86400
        let h = (seconds % 86400) / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if d > 0 { return "\(d)d \(h)h \(m)m \(s)s" }
        if h > 0 { return "\(h)h \(m)m \(s)s" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}

// MARK: - Tip Jar

@MainActor
class TipJarManager: ObservableObject {
    @Published var products: [Product] = []
    @Published var purchasedProductID: String?
    @Published var isLoading = false
    @Published var purchasingProductID: String?
    @Published var lastErrorMessage: String? = nil
    @Published var showSupporterNamePrompt = false

    var purchaseSuccess: Bool { purchasedProductID != nil }

    var thankYouEmoji: String {
        guard let id = purchasedProductID else { return "" }
        if id.hasSuffix(".decent") { return "\u{1F44B}" }
        if id.hasSuffix(".nice") { return "\u{1F60A}" }
        if id.hasSuffix(".great") { return "\u{1F389}" }
        if id.hasSuffix(".help") { return "\u{1F49A}" }
        return "\u{2764}\u{FE0F}"
    }

    var thankYouTitle: String {
        guard let id = purchasedProductID else { return "Thank You!" }
        if id.hasSuffix(".decent") { return "Thanks!" }
        if id.hasSuffix(".nice") { return "You're Awesome!" }
        if id.hasSuffix(".great") { return "Amazing, Thank You!" }
        if id.hasSuffix(".help") { return "You're a Legend!" }
        return "Thank You!"
    }

    var thankYouMessage: String {
        guard let id = purchasedProductID else { return "Your support means a lot." }
        if id.hasSuffix(".decent") { return "Every bit helps keep MeshCore free for everyone." }
        if id.hasSuffix(".nice") { return "Your generosity helps fund new features and improvements." }
        if id.hasSuffix(".great") { return "Seriously, thank you. People like you make MeshCore possible." }
        if id.hasSuffix(".help") { return "You're helping build the future of off-grid communication. Check the Supporters Wall!" }
        return "Your support means a lot."
    }

    struct PlaceholderTip: Identifiable {
        let id: String
        let emoji: String
        let name: String
        let description: String
        let price: String
    }

    static let placeholders: [PlaceholderTip] = [
        PlaceholderTip(id: "decent", emoji: "\u{1F44B}", name: "Decent Try!", description: "Thanks for giving MeshCore a shot", price: "$0.99"),
        PlaceholderTip(id: "nice", emoji: "\u{1F44D}", name: "Nice App!", description: "You're enjoying the mesh life", price: "$2.99"),
        PlaceholderTip(id: "great", emoji: "\u{1F389}", name: "Great Job!", description: "MeshCore has become your go-to client", price: "$4.99"),
        PlaceholderTip(id: "help", emoji: "\u{1F49A}", name: "I Want to Help!", description: "You believe in off-grid communication", price: "$9.99"),
    ]

    nonisolated static let productIDs = [
        "com.mbedworth.meshcore.tip.decent",
        "com.mbedworth.meshcore.tip.nice",
        "com.mbedworth.meshcore.tip.great",
        "com.mbedworth.meshcore.tip.help"
    ]

    func loadProductsIfNeeded() {
        guard !isLoading && products.isEmpty else { return }
        isLoading = true
        lastErrorMessage = nil

        let ids = Set(Self.productIDs)
        DebugLogger.shared.log("TIP JAR: requesting \(ids.count) products: \(ids.sorted().joined(separator: ", "))", level: .info)

        Task {
            let (result, fetchError) = await Self.fetchProducts(ids: ids)
            self.products = result
            self.lastErrorMessage = fetchError
            self.isLoading = false
        }
    }

    private static func fetchProducts(ids: Set<String>) async -> (products: [Product], error: String?) {
        do {
            let fetched = try await Product.products(for: ids)
            let sorted = fetched.sorted { $0.price < $1.price }
            for p in sorted {
                DebugLogger.shared.log("TIP JAR: product \(p.id) — \(p.displayPrice)", level: .info)
            }
            DebugLogger.shared.log("TIP JAR: loaded \(sorted.count) products", level: .info)
            if sorted.isEmpty {
                DebugLogger.shared.log("TIP JAR: no products returned — retrying in 5s", level: .warning)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                let retry = try await Product.products(for: ids)
                let retrySorted = retry.sorted { $0.price < $1.price }
                DebugLogger.shared.log("TIP JAR: retry returned \(retrySorted.count) products", level: .info)
                if retrySorted.isEmpty {
                    let msg = "No products returned after retry — check App Store Connect IAP status and sandbox account"
                    DebugLogger.shared.log("TIP JAR: \(msg)", level: .error)
                    return ([], msg)
                }
                return (retrySorted, nil)
            }
            return (sorted, nil)
        } catch {
            // Log the full error type, not just localizedDescription, to distinguish
            // StoreKitError.notAvailable / .systemError / network errors etc.
            let msg = "StoreKit error: \(error) [\(type(of: error))]"
            DebugLogger.shared.log("TIP JAR: ERROR — \(msg)", level: .error)
            return ([], msg)
        }
    }

    func purchase(_ product: Product) async {
        DebugLogger.shared.log("TIP JAR: purchase START for \(product.id)", level: .info)
        purchasingProductID = product.id

        do {
            DebugLogger.shared.log("TIP JAR: calling product.purchase()", level: .info)
            let result = try await product.purchase()
            DebugLogger.shared.log("TIP JAR: purchase returned for \(product.id)", level: .info)

            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    DebugLogger.shared.log("TIP JAR: verified transaction \(transaction.id)", level: .info)
                    await transaction.finish()
                    self.purchasedProductID = product.id
                    if product.id.hasSuffix(".help") {
                        self.showSupporterNamePrompt = true
                    }
                case .unverified(let transaction, let error):
                    DebugLogger.shared.log("TIP JAR: unverified — \(error.localizedDescription)", level: .warning)
                    await transaction.finish()
                }
            case .pending:
                DebugLogger.shared.log("TIP JAR: pending (Ask to Buy?)", level: .warning)
            case .userCancelled:
                DebugLogger.shared.log("TIP JAR: user cancelled", level: .info)
            @unknown default:
                DebugLogger.shared.log("TIP JAR: unknown result", level: .warning)
            }
        } catch {
            DebugLogger.shared.log("TIP JAR: ERROR — \(error.localizedDescription)", level: .error)
        }

        self.purchasingProductID = nil
    }
}

// MARK: - Supporters Wall (CloudKit)

@MainActor
class SupportersManager: ObservableObject {
    @Published var supporters: [Supporter] = []
    @Published var isLoading = false

    struct Supporter: Identifiable {
        let id: String
        let displayName: String
        let date: Date
    }

    private let container = CKContainer(identifier: "iCloud.com.mbedworth.meshcore")

    @MainActor
    func fetchSupporters() async {
        isLoading = true
        objectWillChange.send()
        DebugLogger.shared.log("SUPPORTERS: fetching from CloudKit public DB...", level: .info)

        let db = container.publicCloudDatabase
        let query = CKQuery(recordType: "Supporter", predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]

        do {
            let (results, cursor) = try await db.records(matching: query)
            DebugLogger.shared.log("SUPPORTERS: query returned \(results.count) results, cursor=\(cursor != nil)", level: .info)
            let fetched: [Supporter] = results.compactMap { (id, result) -> Supporter? in
                switch result {
                case .success(let record):
                    let name = record["displayName"] as? String ?? "(no name)"
                    let date = record["date"] as? Date ?? record.creationDate ?? Date()
                    DebugLogger.shared.log("SUPPORTERS: record \(id.recordName) — \(name)", level: .info)
                    return Supporter(id: id.recordName, displayName: name, date: date)
                case .failure(let error):
                    DebugLogger.shared.log("SUPPORTERS: record \(id.recordName) error — \(error)", level: .error)
                    return nil
                }
            }
            .sorted { $0.date > $1.date }
            DebugLogger.shared.log("SUPPORTERS: updating UI with \(fetched.count) supporters", level: .info)
            self.supporters = fetched
            self.isLoading = false
        } catch {
            DebugLogger.shared.log("SUPPORTERS: fetch error — \(error)", level: .error)
            self.isLoading = false
        }
    }

    func addSupporter(name: String) async -> Bool {
        DebugLogger.shared.log("SUPPORTERS: saving name '\(name)' to CloudKit...", level: .info)

        // Check account status first
        do {
            let status = try await container.accountStatus()
            DebugLogger.shared.log("SUPPORTERS: iCloud account status = \(status.rawValue) (1=available)", level: .info)
            guard status == .available else {
                DebugLogger.shared.log("SUPPORTERS: iCloud not available (status \(status.rawValue)) — cannot save", level: .error)
                return false
            }
        } catch {
            DebugLogger.shared.log("SUPPORTERS: account status check failed — \(error)", level: .error)
            return false
        }

        let db = container.publicCloudDatabase
        let record = CKRecord(recordType: "Supporter")
        record["displayName"] = name as CKRecordValue
        record["date"] = Date() as CKRecordValue

        do {
            let saved = try await db.save(record)
            DebugLogger.shared.log("SUPPORTERS: saved record \(saved.recordID.recordName) for '\(name)'", level: .info)
            await fetchSupporters()
            return true
        } catch {
            DebugLogger.shared.log("SUPPORTERS: save error — \(error)", level: .error)
            return false
        }
    }
}

private extension SettingsView {
    var storageSection: some View {
        Section {
            Picker(selection: $maxMessagesPerContact) {
                Text("50").tag(50)
                Text("100").tag(100)
                Text("200").tag(200)
                Text("500").tag(500)
                Text("1,000").tag(1000)
            } label: {
                Label("Messages Per Contact", systemImage: "number")
            }
            .listRowBackground(MeshTheme.surface)

            Button {
                showPurgeOptions = true
            } label: {
                HStack {
                    Label("Manage Storage", systemImage: "externaldrive")
                        .foregroundStyle(MeshTheme.accent)
                    Spacer()
                    let count = messageStoreManager.messagesByContact.values.reduce(0) { $0 + $1.count }
                    Text("\(count) messages")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(MeshTheme.surface)
            .confirmationDialog("Manage Storage", isPresented: $showPurgeOptions) {
                Button("Clear All Messages", role: .destructive) {
                    messageStoreManager.clearAllMessages()
                }
                Button("Clear Message Drafts") {
                    messageStoreManager.clearAllDrafts()
                }
                Button("Cancel", role: .cancel) {}
            }
        } header: {
            sectionInfoHeader("Storage", info: "Maximum messages stored on this device per contact. Oldest are pruned automatically. iCloud syncs the last 50 per contact separately.")
        }
    }

    var tipJarSection: some View {
        Section {
            #if os(macOS) || targetEnvironment(macCatalyst)
            // macOS/Catalyst: sheet instead of NavigationLink — dismiss() inside a NavigationLink
            // destination in a bare NavigationSplitView detail exits Settings entirely.
            Button {
                showTipJarSheet = true
            } label: {
                HStack {
                    Label("Tip Jar", systemImage: "heart.fill")
                        .foregroundStyle(MeshTheme.accent)
                    Spacer()
                    if tipJar.purchaseSuccess {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(MeshTheme.connected)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(MeshTheme.surface)
            // Sheet is intentionally NOT attached here — see settingsForm for the macOS/Catalyst
            // .sheet(isPresented: $showTipJarSheet) anchor. Attaching .sheet to a List row
            // causes Catalyst to corrupt navigation state when the sheet closes (same class of
            // bug as the iOS Device Info sheet — fixed by lifting to the List level).
            #else
            // iOS: sheet instead of NavigationLink — NavigationLink push in a NavigationSplitView
            // detail column corrupts sidebar selection state on pop (same bug class as macOS).
            Button {
                showTipJarSheet = true
            } label: {
                HStack {
                    Label("Tip Jar", systemImage: "heart.fill")
                        .foregroundStyle(MeshTheme.accent)
                    Spacer()
                    if tipJar.purchaseSuccess {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(MeshTheme.connected)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(MeshTheme.surface)
            #endif

            Button {
                showSupportersSheet = true
            } label: {
                HStack {
                    Label("Supporters Wall", systemImage: "star.fill")
                        .foregroundStyle(.yellow)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(MeshTheme.surface)
        } header: {
            sectionInfoHeader("Support", info: "MeshCore is free with all features. Tips help fund development. \u{1F49A} tippers join the Supporters Wall!")
        }
    }

}

/// MARK: - Tip Jar Standalone View (outside List hierarchy)

struct TipJarView: View {
    @ObservedObject var manager: TipJarManager
    @Environment(\.dismiss) private var dismiss
    @State private var showSupportersSheet = false

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(MeshTheme.accent)
                    .padding(.top, 20)

                Text("Support MeshCore Development")
                    .font(.title2.bold())
                    .foregroundStyle(MeshTheme.textPrimary)

                Text("MeshCore is free with all features unlocked. If you find it useful, consider leaving a tip to support continued development.")
                    .font(.subheadline)
                    .foregroundStyle(MeshTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                if manager.products.isEmpty && manager.isLoading {
                    ProgressView("Loading products...")
                        .padding()
                } else if manager.products.isEmpty {
                    VStack(spacing: 12) {
                        Text("Products unavailable")
                            .foregroundStyle(MeshTheme.textSecondary)
                        if let errorMessage = manager.lastErrorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(MeshTheme.textSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                        Button("Try Again") {
                            manager.loadProductsIfNeeded()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                } else {
                    ForEach(manager.products) { product in
                        TipButton(product: product, manager: manager)
                    }
                }

                if manager.purchaseSuccess {
                    VStack(spacing: 12) {
                        Text(manager.thankYouEmoji)
                            .font(.system(size: 48))
                        Text(manager.thankYouTitle)
                            .font(.title2.bold())
                            .foregroundStyle(MeshTheme.textPrimary)
                        Text(manager.thankYouMessage)
                            .font(.subheadline)
                            .foregroundStyle(MeshTheme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(MeshTheme.surfaceLight)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .transition(.scale.combined(with: .opacity))
                    .id("thankYou")
                }

                Divider()
                    .padding(.vertical, 8)

                Button {
                    showSupportersSheet = true
                } label: {
                    HStack {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                        Text("View Supporters Wall")
                            .foregroundStyle(MeshTheme.accent)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(MeshTheme.textSecondary)
                    }
                    .padding()
                    .background(MeshTheme.surfaceLight)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                Text("\u{1F49A} I Want to Help! tippers can add their name to the Supporters Wall.")
                    .font(.caption)
                    .foregroundStyle(MeshTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding()
            .onChange(of: manager.purchasedProductID) { _, newValue in
                if newValue != nil {
                    withAnimation {
                        proxy.scrollTo("thankYou", anchor: .bottom)
                    }
                }
            }
        }
        } // ScrollViewReader
        .background(MeshTheme.background)
        .navigationTitle("Tip Jar")
        .sheet(isPresented: $showSupportersSheet) {
            NavigationStack {
                SupportersView()
            }
            .meshTheme()
        }
        .toolbar {
            #if targetEnvironment(macCatalyst)
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    DispatchQueue.main.async { dismiss() }
                }
            }
            #elseif os(macOS)
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    DispatchQueue.main.async { dismiss() }
                }
            }
            #else
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") {
                    // Deferred dismiss prevents navigation state corruption when the sheet
                    // closes and the presenting List row re-renders (Catalyst and iOS).
                    DispatchQueue.main.async { dismiss() }
                }
            }
            #endif
        }
        #if !os(macOS) && !targetEnvironment(macCatalyst)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            DebugLogger.shared.log("TIP JAR VIEW: appeared, products=\(manager.products.count)", level: .info)
            manager.loadProductsIfNeeded()
        }
        .onDisappear {
            // Cancel any pending purchase to prevent UI freeze from stuck StoreKit overlay
            manager.purchasingProductID = nil
            DebugLogger.shared.log("TIP JAR VIEW: disappeared, cleaned up", level: .info)
        }
        .onChange(of: manager.purchasedProductID) { _, newValue in
            if newValue != nil {
                // Auto-dismiss after enough time to read the thank-you message
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                    dismiss()
                }
            }
        }
    }
}

struct TipButton: View {
    let product: Product
    @ObservedObject var manager: TipJarManager

    private var emoji: String {
        if product.id.hasSuffix(".decent") { return "\u{1F44B}" }
        if product.id.hasSuffix(".nice") { return "\u{1F44D}" }
        if product.id.hasSuffix(".great") { return "\u{1F389}" }
        if product.id.hasSuffix(".help") { return "\u{1F49A}" }
        return "\u{2764}\u{FE0F}"
    }

    var body: some View {
        Button {
            DebugLogger.shared.log("TIP JAR: BUTTON TAPPED \(product.id)", level: .info)
            Task {
                await manager.purchase(product)
            }
        } label: {
            HStack {
                Text(emoji)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(product.displayName)
                        .font(.headline)
                        .foregroundStyle(MeshTheme.textPrimary)
                    Text(product.description)
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                }
                Spacer()
                if manager.purchasingProductID == product.id {
                    ProgressView()
                        .frame(width: 60)
                } else {
                    Text(product.displayPrice)
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(MeshTheme.interactiveGreen)
                        .foregroundStyle(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding()
            .background(MeshTheme.surfaceLight)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(manager.purchasingProductID != nil)
    }
}

// MARK: - Supporters Wall View

struct SupportersView: View {
    @StateObject private var manager = SupportersManager()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if manager.isLoading && manager.supporters.isEmpty {
                    ProgressView()
                        .padding(.top, 40)
                    Text("Loading supporters...")
                        .foregroundStyle(MeshTheme.textSecondary)
                } else if manager.supporters.isEmpty {
                    Image(systemName: "heart.circle")
                        .font(.system(size: 48))
                        .foregroundStyle(MeshTheme.textSecondary)
                        .padding(.top, 20)
                    Text("No supporters yet")
                        .font(.headline)
                        .foregroundStyle(MeshTheme.textPrimary)
                    Text("Be the first! Leave a \u{1F49A} I Want to Help! tip to join the wall.")
                        .font(.subheadline)
                        .foregroundStyle(MeshTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                } else {
                    Text("These generous people help keep MeshCore free for everyone.")
                        .font(.subheadline)
                        .foregroundStyle(MeshTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    ForEach(manager.supporters) { supporter in
                        HStack {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                            Text(supporter.displayName)
                                .font(.body)
                                .foregroundStyle(MeshTheme.textPrimary)
                            Spacer()
                            Text(supporter.date, style: .date)
                                .font(.caption)
                                .foregroundStyle(MeshTheme.textSecondary)
                        }
                        .padding()
                        .background(MeshTheme.surfaceLight)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .padding()
        }
        .background(MeshTheme.background)
        .navigationTitle("Supporters Wall")
        .toolbar {
            #if targetEnvironment(macCatalyst)
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    DispatchQueue.main.async { dismiss() }
                }
            }
            #elseif os(macOS)
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    DispatchQueue.main.async { dismiss() }
                }
            }
            #else
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") {
                    DispatchQueue.main.async { dismiss() }
                }
            }
            #endif
        }
        #if !os(macOS) && !targetEnvironment(macCatalyst)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            Task {
                await manager.fetchSupporters()
            }
        }
    }
}

// MARK: - Troubleshooting

private extension SettingsView {
    var troubleshootingSection: some View {
        Section {
            Button {
                showConnectionHelp = true
            } label: {
                HStack {
                    Label("Can't Connect to Radio?", systemImage: "questionmark.circle")
                        .foregroundStyle(MeshTheme.accent)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(MeshTheme.surface)
        } header: {
            sectionHeader("Troubleshooting")
        }
        .alert("Connection Troubleshooting", isPresented: $showConnectionHelp) {
            Button("OK") {}
        } message: {
            Text("If your radio won't appear in the scanner:\n\n1. Go to Settings \u{2192} Bluetooth\n2. Find your MeshCore device and tap \u{24D8}\n3. Tap \u{2018}Forget This Device\u{2019}\n4. Power off the radio for 30 seconds\n5. Power it back on and scan again\n\nForce-quitting the app can leave the radio\u{2019}s Bluetooth in a stuck state. A full power cycle clears it.")
        }
    }
}

// MARK: - About

private extension SettingsView {
    var aboutSection: some View {
        Section {
            LabelValueRow(
                label: "App Version",
                value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))"
            )

            if isConnected, !config.semanticVersion.isEmpty {
                LabelValueRow(label: "Firmware", value: config.semanticVersion)
            }

            Link(destination: URL(string: "https://meshcore.co")!) {
                HStack {
                    Text("MeshCore Project")
                        .foregroundStyle(MeshTheme.accent)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(MeshTheme.textSecondary)
                }
            }
            .listRowBackground(MeshTheme.surface)

            Link(destination: URL(string: "https://gist.github.com/mbedworth/7cccc52eec16626a5ad7f5328b456fb3")!) {
                HStack {
                    Text("Privacy Policy")
                        .foregroundStyle(MeshTheme.accent)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(MeshTheme.textSecondary)
                }
            }
            .listRowBackground(MeshTheme.surface)

            Button {
                UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
            } label: {
                HStack {
                    Text("Show Welcome Guide")
                        .foregroundStyle(MeshTheme.accent)
                    Spacer()
                    Image(systemName: "book.pages")
                        .foregroundStyle(MeshTheme.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(MeshTheme.surface)

            Button {
                connectionManager.verifyRadioConfig()
            } label: {
                HStack {
                    Text("Verify Radio Config")
                        .foregroundStyle(MeshTheme.accent)
                    Spacer()
                    if connectionManager.isVerifyingConfig {
                        ProgressView()
                            #if !os(watchOS)
                            .controlSize(.small)
                            #endif
                    } else {
                        Image(systemName: "checkmark.shield")
                            .foregroundStyle(MeshTheme.textSecondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isConnected || connectionManager.isVerifyingConfig)
            .listRowBackground(MeshTheme.surface)

            if let result = connectionManager.lastConfigVerification {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Firmware", value: result.firmware)
                    LabeledContent("Frequency", value: result.frequency)
                    LabeledContent("Bandwidth", value: result.bandwidth)
                    LabeledContent("SF / CR", value: "SF\(result.spreadingFactor) CR\(result.codingRate)")
                    LabeledContent("TX Power", value: result.txPower)
                    LabeledContent("Battery", value: result.battery)
                    Divider()
                    Text(result.regionMessage)
                        .font(.caption)
                        .foregroundStyle(result.regionCheck == .pass ? .green : result.regionCheck == .fail ? .red : .orange)
                }
                .font(.caption)
                .listRowBackground(MeshTheme.surface)
            }

            #if os(macOS) || targetEnvironment(macCatalyst)
            Button {
                showDebugLog = true
            } label: {
                HStack {
                    Text("Debug Log")
                        .foregroundStyle(MeshTheme.accent)
                    Spacer()
                    Text("\(DebugLogger.shared.entries.count)")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(MeshTheme.surface)
            .sheet(isPresented: $showDebugLog) {
                NavigationStack {
                    DebugLogView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showDebugLog = false }
                            }
                            ToolbarItem(placement: .primaryAction) {
                                Menu {
                                    Button {
                                        let text = DebugLogger.shared.exportText()
                                        copyToClipboard(text)
                                    } label: {
                                        Label("Copy All", systemImage: "doc.on.doc")
                                    }
                                    Button(role: .destructive) {
                                        DebugLogger.shared.clear()
                                    } label: {
                                        Label("Clear Log", systemImage: "trash")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .foregroundStyle(MeshTheme.accent)
                                }
                            }
                        }
                }
                .frame(minWidth: 500, minHeight: 400)
            }
            #else
            NavigationLink {
                DebugLogView()
            } label: {
                HStack {
                    Text("Debug Log")
                        .foregroundStyle(MeshTheme.accent)
                    Spacer()
                    Text("\(DebugLogger.shared.entries.count)")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(MeshTheme.textSecondary)
                }
            }
            .listRowBackground(MeshTheme.surface)
            #endif
        } header: {
            sectionInfoHeader("About", info: "Debug Log records connection and protocol events for troubleshooting.")
        }
    }
}

// MARK: - Section 10: Danger Zone (Fix #13: Factory Reset requires typing RESET)

private extension SettingsView {
    var dangerZoneSection: some View {
        DangerZoneSection()
    }
}

struct DangerZoneSection: View {
    @Environment(ConnectionManager.self) private var connectionManager
    @State private var showRebootConfirm = false
    @State private var showResetConfirm = false
    @State private var resetConfirmText = ""

    var body: some View {
        Section {
            Button {
                showRebootConfirm = true
            } label: {
                HStack {
                    Image(systemName: "arrow.counterclockwise.circle")
                        .foregroundStyle(.orange)
                        .frame(width: 24)
                    Text("Reboot Device")
                        .foregroundStyle(.orange)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(MeshTheme.surface)
            .alert("Reboot Device?", isPresented: $showRebootConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Reboot", role: .destructive) {
                    connectionManager.sendCommand(MeshCoreProtocol.buildReboot(), label: "REBOOT")
                }
            } message: {
                Text("The radio will disconnect and restart. You'll need to reconnect via Bluetooth.")
            }

            Button {
                resetConfirmText = ""
                showResetConfirm = true
            } label: {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .frame(width: 24)
                    Text("Factory Reset")
                        .foregroundStyle(.red)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(MeshTheme.surface)
            .alert("Factory Reset?", isPresented: $showResetConfirm) {
                TextField("Type RESET to confirm", text: $resetConfirmText)
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) {
                    if resetConfirmText == "RESET" {
                        connectionManager.sendCommand(MeshCoreProtocol.buildFactoryReset(), label: "FACTORY_RESET")
                        connectionManager.lastErrorMessage = "Radio has been factory reset. Power cycle the radio, then go to Settings \u{2192} Bluetooth and tap \"Forget This Device\" before pairing again."
                        // Delay disconnect to let the BLE write complete
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            connectionManager.disconnect()
                        }
                    }
                }
                .disabled(resetConfirmText != "RESET")
            } message: {
                Text("This will erase all data and cannot be undone.\n\nType RESET to confirm.")
            }
        } header: {
            SectionInfoHeader(title: "Danger Zone", info: "Factory reset erases all contacts, channels, settings, and encryption keys from the device. This cannot be undone.", titleColor: .red)
        }
    }
}

// MARK: - Save Button with Feedback (Fix #14)

enum SaveButtonState {
    case idle, saved
}

struct SaveButton: View {
    let state: SaveButtonState
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if state == .saved {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Saved")
                        .foregroundStyle(.green)
                } else {
                    Text(label)
                        .foregroundStyle(MeshTheme.accent)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .listRowBackground(MeshTheme.surface)
        .animation(.easeInOut(duration: 0.2), value: state)
    }
}

/// Tappable ⓘ button for individual rows. Drop it at the trailing end of any HStack.
/// Each call site supplies its own help text; state is local to each instance.
/// Shared popover/sheet content for ⓘ help text.
/// On iPhone the .popover adapts to a sheet — content sizes itself to fit all text.
/// On iPad/macOS it shows as a real popover anchored to the button.
private struct InfoPopoverContent: View {
    let text: String

    var body: some View {
        #if os(macOS) || targetEnvironment(macCatalyst)
        // macOS/Catalyst: let the text determine the popover height.
        // Using ScrollView with a fixed frame forces scrolling; fixedSize lets the
        // popover grow to fit its content so no scrolling is required.
        Text(text)
            .font(.callout)
            .lineLimit(nil)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
            .frame(minWidth: 240, maxWidth: 340)
        #else
        ScrollView {
            Text(text)
                .font(.callout)
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
        }
        .frame(minWidth: 240, maxWidth: 300, minHeight: 60)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }
}

struct InfoButton: View {
    let text: String
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover = true
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(MeshTheme.textSecondary.opacity(0.75))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover) {
            InfoPopoverContent(text: text)
        }
    }
}

/// Section header combining a title with a tappable ⓘ icon.
/// Tap the icon to reveal the full help text as a popover.
struct SectionInfoHeader: View {
    let title: String
    let info: String
    var titleColor: Color?
    @State private var showInfo = false

    var body: some View {
        let color = titleColor ?? MeshTheme.textSecondary
        HStack(spacing: 6) {
            if !title.isEmpty {
                Text(title)
                    .foregroundStyle(color)
            }
            Spacer(minLength: 0)
            Button {
                showInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(color.opacity(0.75))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showInfo) {
                InfoPopoverContent(text: info)
            }
        }
    }
}

/// Trigger saved feedback: show "Saved" for 2 seconds then revert.
func showSaved(_ state: Binding<SaveButtonState>) {
    state.wrappedValue = .saved
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        state.wrappedValue = .idle
    }
}

// MARK: - Helpers

private extension SettingsView {
    var config: DeviceConfig { deviceConfig }

    func infoRow(icon: String, label: String, value: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(MeshTheme.accent)
                .frame(width: 24)
            Text(label)
                .foregroundStyle(MeshTheme.accent)
            Spacer()
            Text(value)
                .foregroundStyle(MeshTheme.textPrimary)
                .textSelection(.enabled)
        }
        .listRowBackground(MeshTheme.surface)
    }

    func sectionHeader(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(MeshTheme.textSecondary)
    }

    func sectionInfoHeader(_ title: String, info: String) -> some View {
        SectionInfoHeader(title: title, info: info)
    }

    func detectRadioPreset(freqKHz: Double, bw: Double, sf: UInt8, cr: UInt8) -> String? {
        radioPresets.first { p in
            abs(p.frequencyKHz - freqKHz) < 2.0 &&
            abs(p.bandwidth - bw) < 0.5 &&
            p.spreadingFactor == sf &&
            p.codingRate == cr
        }?.name
    }
}

// MARK: - Editor Sheets

struct NameEditorSheet: View {

    @Environment(DeviceConfig.self) private var deviceConfig
    @Environment(ConnectionManager.self) private var connectionManager
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Device Name", text: $name)
                        .onChange(of: name) { _, newValue in
                            if newValue.count > 31 { name = String(newValue.prefix(31)) }
                        }
                    Text("\(name.count)/31")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    InfoButton(text: "TIP: Use your initials + first 4 of your public key (e.g., NMA-5abd). Max 31 characters.")
                }
            }
        }
        .navigationTitle("Device Name")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if targetEnvironment(macCatalyst)
            ToolbarItem(placement: .topBarTrailing) {
                Button("Apply") {
                    connectionManager.setAdvertName(name)
                    dismiss()
                }
                .disabled(name.isEmpty)
            }
            #elseif os(macOS)
            ToolbarItem(placement: .primaryAction) {
                Button("Apply") {
                    connectionManager.setAdvertName(name)
                    dismiss()
                }
                .disabled(name.isEmpty)
            }
            #else
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Apply") {
                    connectionManager.setAdvertName(name)
                    dismiss()
                }
                .disabled(name.isEmpty)
            }
            #endif
        }
        .onAppear {
            name = deviceConfig.deviceName
        }
    }
}

struct FirmwareDetailSheet: View {
    @Environment(DeviceConfig.self) private var deviceConfig
    @Environment(\.dismiss) private var dismiss
    @State private var version = ""
    @State private var buildDate = ""
    @State private var model = ""
    @State private var maxContacts: UInt16 = 0
    @State private var maxChannels: UInt8 = 0
    @State private var publicKeyHex = ""
    @State private var clockDate: Date?

    var body: some View {
        List {
            Section {
                LabeledContent("Version", value: version.isEmpty ? "\u{2014}" : version)
                LabeledContent("Build Date", value: buildDate.isEmpty ? "\u{2014}" : buildDate)
                LabeledContent("Model", value: model.isEmpty ? "\u{2014}" : model)
            } header: {
                SectionInfoHeader(title: "", info: "Hardware and firmware details from your radio.")
            }
            Section {
                LabeledContent("Max Contacts", value: "\(maxContacts)")
                LabeledContent("Max Channels", value: "\(maxChannels)")
            }
            if !publicKeyHex.isEmpty {
                Section {
                    LabeledContent("Public Key", value: String(publicKeyHex.prefix(16)) + "...")
                        .textSelection(.enabled)
                } header: {
                    SectionInfoHeader(title: "", info: "Long-press to copy. Share this with others to let them add you as a contact.")
                }
            }
            Section {
                if let date = clockDate {
                    LabeledContent("Device Clock") {
                        Text(date, style: .date) + Text(" ") + Text(date, style: .time)
                    }
                }
                LabeledContent("Clock Status", value: "Auto-synced on connect")
            } header: {
                SectionInfoHeader(title: "Time", info: "Device clock is automatically synced from your phone on every connection.")
            }
        }
        .meshListStyle()
        .navigationTitle("Device Details")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            version = deviceConfig.semanticVersion.isEmpty ? "v\(deviceConfig.firmwareVersion)" : deviceConfig.semanticVersion
            buildDate = deviceConfig.buildDate
            model = deviceConfig.manufacturer
            maxContacts = deviceConfig.maxContacts
            maxChannels = deviceConfig.maxChannels
            publicKeyHex = deviceConfig.publicKeyHex
            clockDate = deviceConfig.deviceTimeDate
        }
    }
}

// MARK: - TX Power Editor

struct TxPowerEditorSheet: View {

    @Environment(DeviceConfig.self) private var deviceConfig
    @Environment(ConnectionManager.self) private var connectionManager
    @Environment(\.dismiss) private var dismiss
    @State private var txPower: Double = 22
    @State private var maxPower: Double = 22
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("TX Power")
                    Spacer()
                    if saved {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(MeshTheme.connected)
                    }
                    Text("\(Int(txPower)) dBm").fontWeight(.medium)
                    InfoButton(text: "Higher power = more range but more battery drain. Max \(Int(maxPower)) dBm for this device.")
                }
                Slider(value: $txPower, in: 1...max(maxPower, 2), step: 1)
                    .tint(MeshTheme.accent)
                    .onChange(of: txPower) { _, newValue in
                        connectionManager.setRadioTXPower(UInt8(newValue))
                        saved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { saved = false }
                    }
            }
        }
        .navigationTitle("TX Power")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            txPower = Double(deviceConfig.radioTXPower)
            maxPower = Double(deviceConfig.maxTXPower)
        }
    }
}

// MARK: - Tuning Editor

struct TuningEditorSheet: View {

    @Environment(DeviceConfig.self) private var deviceConfig
    @Environment(ConnectionManager.self) private var connectionManager
    @Environment(\.dismiss) private var dismiss
    @State private var rxDelay: Double = 0
    @State private var airtimeFactor: Double = 0

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("RX Delay")
                    Spacer()
                    Text("\(String(format: "%.1f", rxDelay))s").fontWeight(.medium)
                    InfoButton(text: "Base delay for SNR-based packet prioritization. Higher values give better-signal packets more priority. 0 = disabled.")
                }
                Slider(value: $rxDelay, in: 0...20, step: 0.5)
                    .tint(MeshTheme.accent)
            }

            Section {
                HStack {
                    Text("Airtime Factor")
                    Spacer()
                    Text("\(String(format: "%.1f", airtimeFactor))x").fontWeight(.medium)
                    InfoButton(text: "Multiplier for airtime budget. Higher values allow more frequent transmissions. 0 = no limit.")
                }
                Slider(value: $airtimeFactor, in: 0...9, step: 0.5)
                    .tint(MeshTheme.accent)
            }
        }
        .navigationTitle("Tuning")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if targetEnvironment(macCatalyst)
            ToolbarItem(placement: .topBarTrailing) {
                Button("Apply") {
                    let rx = UInt32(rxDelay * 1000)
                    let air = UInt32(airtimeFactor * 1000)
                    connectionManager.setTuningParams(rxDelayBase: rx, airtimeFactor: air)
                    dismiss()
                }
            }
            #elseif os(macOS)
            ToolbarItem(placement: .primaryAction) {
                Button("Apply") {
                    let rx = UInt32(rxDelay * 1000)
                    let air = UInt32(airtimeFactor * 1000)
                    connectionManager.setTuningParams(rxDelayBase: rx, airtimeFactor: air)
                    dismiss()
                }
            }
            #else
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Apply") {
                    let rx = UInt32(rxDelay * 1000)
                    let air = UInt32(airtimeFactor * 1000)
                    connectionManager.setTuningParams(rxDelayBase: rx, airtimeFactor: air)
                    dismiss()
                }
            }
            #endif
        }
        .onAppear {
            rxDelay = deviceConfig.rxDelaySeconds
            airtimeFactor = deviceConfig.airtimeMultiplier
        }
    }
}

// MARK: - GPS Editor

struct GPSEditorSheet: View {

    @Environment(DeviceConfig.self) private var deviceConfig
    @Environment(ConnectionManager.self) private var connectionManager
    @Environment(\.dismiss) private var dismiss
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var gpsSyncFeedback = false
    @AppStorage("autoUpdateLocation") private var autoUpdateLocation = false
    @AppStorage("locationUpdateInterval") private var locationUpdateInterval = 900

    var body: some View {
        Form {
            Section {
                LabeledContent("Latitude", value: latitude.isEmpty ? "\u{2014}" : latitude)
                LabeledContent("Longitude", value: longitude.isEmpty ? "\u{2014}" : longitude)
            } header: {
                SectionInfoHeader(title: "", info: "Your radio\u{2019}s stored coordinates. These are shared with other radios when advertising.")
            }

            #if !os(watchOS)
            Section {
                Button {
                    guard let location = SharedLocation.manager.location else { return }
                    let (fLat, fLon) = MeshCoreViewModel.fudgeLocation(lat: location.coordinate.latitude, lon: location.coordinate.longitude)
                    latitude = formatCoordinate(fLat)
                    longitude = formatCoordinate(fLon)
                    connectionManager.setAdvertLatLon(latitude: fLat, longitude: fLon)
                    showFeedback($gpsSyncFeedback)
                } label: {
                    Label(gpsSyncFeedback ? "Location Set!" : "Set from Phone GPS", systemImage: "iphone.radiowaves.left.and.right")
                        .foregroundStyle(gpsSyncFeedback ? .green : MeshTheme.accent)
                }

                Toggle(isOn: $autoUpdateLocation) {
                    Label("Auto-Update", systemImage: "location.fill.viewfinder")
                }
                .tint(MeshTheme.accent)
                .onChange(of: autoUpdateLocation) { _, enabled in
                    if enabled { connectionManager.startAutoLocationUpdates(interval: locationUpdateInterval) }
                    else { connectionManager.stopAutoLocationUpdates() }
                }

                if autoUpdateLocation {
                    Picker("Interval", selection: $locationUpdateInterval) {
                        Text("5 min").tag(300)
                        Text("15 min").tag(900)
                        Text("30 min").tag(1800)
                        Text("1 hour").tag(3600)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: locationUpdateInterval) { _, interval in
                        if autoUpdateLocation { connectionManager.startAutoLocationUpdates(interval: interval) }
                    }
                }
            } header: {
                SectionInfoHeader(title: "", info: "Set from Phone GPS copies your phone\u{2019}s coordinates to the radio. Auto-Update periodically refreshes while the app is open.")
            }
            #endif
        }
        .navigationTitle("GPS & Location")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            if deviceConfig.latitude != 0 { latitude = formatCoordinate(deviceConfig.latitude) }
            if deviceConfig.longitude != 0 { longitude = formatCoordinate(deviceConfig.longitude) }
        }
    }
}

// MARK: - Battery Editor

struct BatteryEditorSheet: View {
    @Environment(DeviceConfig.self) private var deviceConfig
    @Environment(\.dismiss) private var dismiss
    @Binding var batteryChemistryRaw: String
    @State private var voltageText = ""
    @State private var percentText = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Voltage", value: voltageText)
                LabeledContent("Percentage", value: percentText)
            } header: {
                SectionInfoHeader(title: "", info: "Live reading from the radio\u{2019}s battery sensor. Accuracy depends on correct chemistry selection below.")
            }
            Section {
                Picker("Battery Type", selection: $batteryChemistryRaw) {
                    Text("LiPo (3.7V)").tag(BatteryChemistry.lipo.rawValue)
                    Text("LiFePO4 (3.2V)").tag(BatteryChemistry.lifepo4.rawValue)
                    Text("Li-Ion (3.7V)").tag(BatteryChemistry.li18650.rawValue)
                }
            } header: {
                SectionInfoHeader(title: "", info: "Select battery chemistry for accurate percentage calculation.")
            }
        }
        .navigationTitle("Battery")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            let battV = String(format: "%.2f", Double(deviceConfig.batteryMillivolts) / 1000.0)
            let battPct = deviceConfig.batteryPercent()
            voltageText = "\(battV)V"
            percentText = battPct > 0 ? "\(battPct)%" : "\u{2014}"
        }
    }
}

// MARK: - Blocked Contacts View

struct BlockedContactsView: View {
    @Environment(ContactStore.self) private var contactStore

    var body: some View {
        List {
            if contactStore.blockedContacts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "hand.raised.slash")
                        .font(.system(size: 32))
                        .foregroundStyle(MeshTheme.textSecondary)
                    Text("No Blocked Contacts")
                        .font(.headline)
                    Text("Blocked contacts won't appear in your contact list and their messages will be suppressed.")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 8)
                .listRowBackground(MeshTheme.surface)
            } else {
                ForEach(contactStore.blockedContacts) { contact in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(contactStore.displayName(for: contact))
                                .foregroundStyle(MeshTheme.textPrimary)
                            Text(contact.type.displayName)
                                .font(.caption)
                                .foregroundStyle(MeshTheme.textSecondary)
                        }
                        Spacer()
                        Button("Unblock") {
                            contactStore.unblockContact(contact)
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(MeshTheme.accent)
                    }
                    .listRowBackground(MeshTheme.surface)
                }
            }
        }
        .meshListStyle()
        .navigationTitle("Blocked Contacts")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
