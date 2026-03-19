import SwiftUI
import StoreKit
import LocalAuthentication
import MeshCoreKit
#if !os(watchOS)
import CoreLocation
#endif

struct SettingsView: View {
    @EnvironmentObject var viewModel: MeshCoreViewModel
    @AppStorage("batteryChemistry") private var batteryChemistryRaw: String = BatteryChemistry.lipo.rawValue
    @AppStorage("appTheme") private var appTheme: String = AppTheme.system.rawValue
    @State private var statsExpanded = false
    @State private var clockSynced = false
    @StateObject private var tipJar = TipJarManager()
    @State private var radioToDelete: String?
    @State private var showDeleteRadioConfirm = false
    @State private var radioToMigrate: String?
    @State private var showMigrateSheet = false
    @State private var showConnectionHelp = false
    @State private var showPurgeOptions = false

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
        .onAppear {
            if isConnected {
                viewModel.refreshAllSettings()
            }
        }
    }

    private var isConnected: Bool {
        viewModel.connectionState == .ready || viewModel.connectionState == .connected
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
    }

    // MARK: - Settings Form

    private var settingsForm: some View {
        List {
            // Essential — always visible
            deviceInfoSection
            connectionSection
            identitySection
            notificationsSection
            messageSettingsSection
            privacySection

            // Radio & Advanced — collapsed by default
            Section {
                DisclosureGroup("Radio & Tuning") {
                    radioSection
                    tuningSection
                }
                .listRowBackground(MeshTheme.surface)
            }

            Section {
                DisclosureGroup("Advanced") {
                    appearanceSection
                    iCloudSection
                    radioDataSection
                    timeSection
                    if !viewModel.deviceConfig.customVars.isEmpty {
                        customVarsSection
                    }
                    statsSection
                    storageSection
                }
                .listRowBackground(MeshTheme.surface)
            }

            securitySection
            tipJarSection
            troubleshootingSection
            aboutSection
            dangerZoneSection
        }
        .meshListStyle()
        #if os(macOS)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 40)
        }
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    viewModel.refreshAllSettings()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(MeshTheme.accent)
                }
                .help("Refresh all settings")
            }
        }
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
        } header: {
            sectionHeader("iCloud")
        } footer: {
            Text("Syncs nicknames, notes, channel secrets, login credentials, and recent messages between your Apple devices via iCloud. Data is encrypted by Apple in transit and at rest. Messages are stored per radio \u{2014} switching radios keeps data separate.")
                .font(.caption2)
        }
    }

    private var iCloudSyncBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.object(forKey: "iCloudSyncEnabled") == nil ? true : UserDefaults.standard.bool(forKey: "iCloudSyncEnabled") },
            set: { UserDefaults.standard.set($0, forKey: "iCloudSyncEnabled") }
        )
    }

    var radioDataSection: some View {
        RadioDataSection(viewModel: viewModel, radioToDelete: $radioToDelete, showDeleteRadioConfirm: $showDeleteRadioConfirm, radioToMigrate: $radioToMigrate, showMigrateSheet: $showMigrateSheet)
    }
}

struct RadioDataSection: View {
    @ObservedObject var viewModel: MeshCoreViewModel
    @Binding var radioToDelete: String?
    @Binding var showDeleteRadioConfirm: Bool
    @Binding var radioToMigrate: String?
    @Binding var showMigrateSheet: Bool

    private var currentRadioPrefix: String? {
        let hex = viewModel.deviceConfig.publicKeyHex
        return hex.isEmpty ? nil : String(hex.prefix(12))
    }

    private var knownRadios: [String] {
        let store = NSUbiquitousKeyValueStore.default
        let allKeys = store.dictionaryRepresentation.keys
        var prefixes = Set<String>()
        for key in allKeys where key.hasPrefix("msg.") {
            let parts = key.dropFirst(4) // remove "msg."
            if let dot = parts.firstIndex(of: ".") {
                prefixes.insert(String(parts[parts.startIndex..<dot]))
            }
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
                            Text("\(messageCountForRadio(radioPrefix)) messages synced")
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
                Text("Radio Data")
                    .foregroundStyle(MeshTheme.textSecondary)
            } footer: {
                Text("Each radio stores messages separately. If you replace a radio, use \u{2018}Migrate\u{2019} to move history to your new device.")
                    .font(.caption2)
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
        let radioKeys = allKeys.filter { $0.hasPrefix("msg.\(radioPrefix).") }
        for key in radioKeys {
            store.removeObject(forKey: key)
        }
        store.synchronize()
    }

    private func migrateRadioData(from oldPrefix: String, to newPrefix: String) {
        let store = NSUbiquitousKeyValueStore.default
        let allKeys = store.dictionaryRepresentation.keys
        let oldKeys = allKeys.filter { $0.hasPrefix("msg.\(oldPrefix).") }
        for oldKey in oldKeys {
            let contactSuffix = oldKey.replacingOccurrences(of: "msg.\(oldPrefix).", with: "")
            let newKey = "msg.\(newPrefix).\(contactSuffix)"
            if let data = store.data(forKey: oldKey) {
                store.set(data, forKey: newKey)
            }
        }
        store.synchronize()
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
        } header: {
            sectionHeader("Appearance")
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
            Text("Notifications")
                .foregroundStyle(MeshTheme.textSecondary)
        } footer: {
            Text("Choose which events trigger notifications when the app is in the background.")
                .font(.caption2)
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

            Toggle(isOn: channelEchoBinding) {
                Label("Channel Echo Detection", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(MeshTheme.accent)
            }
            .tint(MeshTheme.accent)
            .listRowBackground(MeshTheme.surface)
        } header: {
            Text("Message Delivery")
                .foregroundStyle(MeshTheme.textSecondary)
        } footer: {
            Text("Auto Retry resends failed direct messages up to 3 times. Auto Reset Path clears the cached route and resends as flood. Channel Echo Detection shows a 'Repeated' indicator when nearby repeaters rebroadcast your channel messages.")
                .font(.caption2)
        }
    }

    private var channelEchoBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: "channelEchoDetection") },
            set: { UserDefaults.standard.set($0, forKey: "channelEchoDetection") }
        )
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
        Section {
            infoRow(icon: "tag", label: "Name", value: config.deviceName.isEmpty ? (viewModel.connectedDeviceName ?? "\u{2014}") : config.deviceName)
            infoRow(icon: "cpu", label: "Firmware", value: config.semanticVersion.isEmpty ? (config.firmwareVersion.isEmpty ? "\u{2014}" : "v\(config.firmwareVersion)") : "\(config.semanticVersion) (\(config.buildDate))")
            if !config.manufacturer.isEmpty {
                infoRow(icon: "building.2", label: "Model", value: config.manufacturer)
            }
            if config.radioFrequency > 0 {
                let freqMHz = String(format: "%.3f", Double(config.radioFrequency) / 1000.0)
                let bwKHz = String(format: "%.1f", Double(config.radioBandwidth) / 1000.0)
                infoRow(icon: "antenna.radiowaves.left.and.right", label: "Radio", value: "\(freqMHz) MHz \u{2022} \(bwKHz)kHz \u{2022} SF\(config.radioSpreadingFactor) CR\(config.radioCodingRate)")
                infoRow(icon: "bolt.fill", label: "TX Power", value: "\(config.radioTXPower)/\(config.maxTXPower) dBm")
            }
            if config.maxContacts > 0 {
                infoRow(icon: "person.2", label: "Capacity", value: "\(viewModel.contacts.count)/\(config.maxContacts) contacts \u{2022} \(viewModel.channels.count)/\(config.maxChannels) channels")
            }
            if !config.publicKeyHex.isEmpty {
                publicKeyRow
            }
            batteryRow
            batteryChemistryPicker
            if viewModel.batteryCalibration != nil {
                batteryCalibrationsRows
            }
        } header: {
            sectionHeader("Device Info")
        }
    }

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
            .onChange(of: batteryChemistryRaw) { _ in
                viewModel.resetBatteryCalibration()
            }
        }
        .listRowBackground(MeshTheme.surface)
    }

    var statsBatteryDisplay: String {
        guard config.statsBatteryMV != 0 else { return "\u{2014}" }
        let mv = Int(config.statsBatteryMV)
        if let cal = viewModel.batteryCalibration {
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
                #if os(iOS)
                UIPasteboard.general.string = config.publicKeyHex
                #elseif os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(config.publicKeyHex, forType: .string)
                #endif
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
        if let cal = viewModel.batteryCalibration {
            let correctedMV = cal.correctedMillivolts(config.batteryMillivolts)
            return batteryChemistry.profile.percentage(forMillivolts: correctedMV)
        }
        return config.batteryPercent(chemistry: batteryChemistry)
    }

    var correctedBatteryVoltage: Double {
        if let cal = viewModel.batteryCalibration {
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
            if let cal = viewModel.batteryCalibration, config.batteryMillivolts > 0 {
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
                    viewModel.resetBatteryCalibration()
                } label: {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                            .foregroundStyle(MeshTheme.accent)
                            .frame(width: 24)
                        Text("Reset Calibration")
                            .foregroundStyle(MeshTheme.accent)
                    }
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

            if viewModel.connectionState != .disconnected {
                Button(role: .destructive) {
                    viewModel.disconnect()
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
            sectionHeader("Connection")
        }
    }

    var statusColor: Color {
        switch viewModel.connectionState {
        case .ready: MeshTheme.connected
        case .connected, .connecting: MeshTheme.connecting
        case .scanning: MeshTheme.scanning
        case .disconnected: MeshTheme.disconnected
        }
    }

    var connectionLabel: String {
        switch viewModel.connectionState {
        case .ready: "Ready"
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .scanning: "Scanning"
        case .disconnected: "Disconnected"
        }
    }
}

// MARK: - Section 3: Identity & Advertising (Fix #1: lat/lon binding)

private extension SettingsView {
    var identitySection: some View {
        IdentitySection(viewModel: viewModel)
    }
}

struct IdentitySection: View {
    @ObservedObject var viewModel: MeshCoreViewModel
    @State private var advertName: String = ""
    @State private var latitude: String = ""
    @State private var longitude: String = ""
    @State private var saveState: SaveButtonState = .idle
    @State private var showAdvertOptions = false
    @State private var showAdvertSent = false
    @State private var gpsSyncFeedback = false
    @AppStorage("autoUpdateLocation") private var autoUpdateLocation = false
    @AppStorage("locationUpdateInterval") private var locationUpdateInterval = 900

    var body: some View {
        Section {
            HStack {
                Image(systemName: "person.text.rectangle")
                    .foregroundStyle(MeshTheme.accent)
                    .frame(width: 24)
                #if os(watchOS)
                TextField("Advert Name", text: $advertName)
                    .foregroundStyle(MeshTheme.textPrimary)
                #else
                TextField("Advert Name", text: $advertName)
                    .foregroundStyle(MeshTheme.textPrimary)
                    .textFieldStyle(MeshTextFieldStyle())
                #endif
            }
            .listRowBackground(MeshTheme.surface)

            HStack {
                Image(systemName: "location")
                    .foregroundStyle(MeshTheme.accent)
                    .frame(width: 24)
                #if os(watchOS)
                TextField("Latitude", text: $latitude)
                    .foregroundStyle(MeshTheme.textPrimary)
                TextField("Longitude", text: $longitude)
                    .foregroundStyle(MeshTheme.textPrimary)
                #else
                TextField("Latitude", text: $latitude)
                    .foregroundStyle(MeshTheme.textPrimary)
                    .textFieldStyle(MeshTextFieldStyle())
                TextField("Longitude", text: $longitude)
                    .foregroundStyle(MeshTheme.textPrimary)
                    .textFieldStyle(MeshTextFieldStyle())
                #endif
            }
            .listRowBackground(MeshTheme.surface)

            #if !os(watchOS)
            Button {
                setLocationFromPhone()
            } label: {
                HStack {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .foregroundStyle(MeshTheme.accent)
                        .frame(width: 24)
                    Text(gpsSyncFeedback ? "Location Set!" : "Set from Phone GPS")
                        .foregroundStyle(gpsSyncFeedback ? .green : MeshTheme.accent)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(MeshTheme.surface)

            Toggle(isOn: $autoUpdateLocation) {
                HStack {
                    Image(systemName: "location.fill.viewfinder")
                        .foregroundStyle(MeshTheme.accent)
                        .frame(width: 24)
                    Text("Auto-Update Location")
                        .foregroundStyle(MeshTheme.accent)
                }
            }
            .tint(MeshTheme.accent)
            .listRowBackground(MeshTheme.surface)
            .onChange(of: autoUpdateLocation) { enabled in
                if enabled {
                    viewModel.startAutoLocationUpdates(interval: locationUpdateInterval)
                } else {
                    viewModel.stopAutoLocationUpdates()
                }
            }

            if autoUpdateLocation {
                Picker("Update Interval", selection: $locationUpdateInterval) {
                    Text("Every 5 minutes").tag(300)
                    Text("Every 15 minutes").tag(900)
                    Text("Every 30 minutes").tag(1800)
                    Text("Every hour").tag(3600)
                }
                .foregroundStyle(MeshTheme.accent)
                .tint(MeshTheme.accent)
                .listRowBackground(MeshTheme.surface)
                .onChange(of: locationUpdateInterval) { newInterval in
                    if autoUpdateLocation {
                        viewModel.startAutoLocationUpdates(interval: newInterval)
                    }
                }
            }
            #endif

            HStack(spacing: 12) {
                SaveButton(state: saveState, label: "Save Identity") {
                    viewModel.setAdvertName(advertName)
                    if let lat = Double(latitude), let lon = Double(longitude) {
                        viewModel.setAdvertLatLon(latitude: lat, longitude: lon)
                    }
                    showSaved($saveState)
                }

                Spacer()

                Button {
                    showAdvertOptions = true
                } label: {
                    Label(showAdvertSent ? "Sent!" : "Advertise", systemImage: "dot.radiowaves.left.and.right")
                        .foregroundStyle(showAdvertSent ? .green : MeshTheme.accent)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
            .listRowBackground(MeshTheme.surface)
        } header: {
            Text("Identity & Advertising")
                .foregroundStyle(MeshTheme.textSecondary)
        } footer: {
            Text("TIP: Use a short, unique name like \u{2018}NMA-5abd\u{2019} (your initials + first 4 of your public key). If your radio lacks GPS, use \u{2018}Set from Phone GPS\u{2019} to send your phone\u{2019}s location to the radio. Auto-Update periodically syncs your position. GPS privacy fudge is applied.")
                .font(.caption2)
        }
        .confirmationDialog("Send Advertisement", isPresented: $showAdvertOptions) {
            Button("Zero-Hop (nearby only)") {
                viewModel.sendAdvertise(type: 0)
                showAdvertSent = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showAdvertSent = false }
            }
            Button("Flood (entire mesh)") {
                viewModel.sendAdvertise(type: 1)
                showAdvertSent = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showAdvertSent = false }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Zero-hop reaches nearby nodes only. Flood is relayed by repeaters across the entire mesh network.")
        }
        .onAppear { loadFromConfig() }
        .onChange(of: viewModel.deviceConfig.deviceName) { _ in loadFromConfig() }
        .onChange(of: viewModel.deviceConfig.latitude) { _ in loadFromConfig() }
    }

    private func loadFromConfig() {
        let c = viewModel.deviceConfig
        if advertName.isEmpty { advertName = c.deviceName }
        if latitude.isEmpty && c.latitude != 0 {
            latitude = String(format: "%.6f", c.latitude)
        }
        if longitude.isEmpty && c.longitude != 0 {
            longitude = String(format: "%.6f", c.longitude)
        }
    }

    #if !os(watchOS)
    private func setLocationFromPhone() {
        let locManager = CLLocationManager()
        guard let location = locManager.location else {
            DebugLogger.shared.log("PHONE GPS: location unavailable", level: .warning)
            return
        }
        let (fLat, fLon) = viewModel.fudgeLocation(
            lat: location.coordinate.latitude,
            lon: location.coordinate.longitude
        )
        latitude = String(format: "%.6f", fLat)
        longitude = String(format: "%.6f", fLon)
        viewModel.setAdvertLatLon(latitude: fLat, longitude: fLon)
        gpsSyncFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { gpsSyncFeedback = false }
        DebugLogger.shared.log("PHONE GPS: set radio location to \(String(format: "%.6f", fLat)), \(String(format: "%.6f", fLon))", level: .tx)
    }
    #endif
}

// MARK: - Section 4: Radio Configuration (Fixes #3, #4, #5, #6)

private extension SettingsView {
    var radioSection: some View {
        RadioSection(viewModel: viewModel)
    }
}

/// Standard LoRa bandwidths in kHz
private let loraBandwidths: [Double] = [7.8, 10.4, 15.6, 20.8, 31.25, 41.7, 62.5, 125, 250, 500]

struct RadioPreset: Identifiable {
    let id = UUID()
    let name: String
    let region: String
    let frequencyKHz: Double
    let bandwidth: Double
    let spreadingFactor: UInt8
    let codingRate: UInt8
}

/// Reusable radio preset picker section. Calls `onApply` with the selected preset.
struct RadioPresetPicker: View {
    let onApply: (RadioPreset) -> Void
    @State private var selectedPresetIndex: Int = -1
    @State private var presetToConfirm: RadioPreset?

    var body: some View {
        Section {
            HStack {
                Image(systemName: "globe")
                    .foregroundStyle(MeshTheme.accent)
                    .frame(width: 24)
                Picker("Radio Preset", selection: $selectedPresetIndex) {
                    Text("Custom").tag(-1)
                    ForEach(Array(radioPresets.enumerated()), id: \.offset) { index, preset in
                        Text(preset.name).tag(index)
                    }
                }
                .foregroundStyle(MeshTheme.accent)
                .tint(MeshTheme.accent)
            }
            .listRowBackground(MeshTheme.surface)

            if selectedPresetIndex >= 0, selectedPresetIndex < radioPresets.count {
                let preset = radioPresets[selectedPresetIndex]
                VStack(alignment: .leading, spacing: 4) {
                    Text("Frequency: \(String(format: "%.3f", preset.frequencyKHz / 1000)) MHz")
                    Text("Bandwidth: \(preset.bandwidth == preset.bandwidth.rounded() ? "\(Int(preset.bandwidth)) kHz" : "\(preset.bandwidth) kHz")")
                    Text("Spreading Factor: SF\(preset.spreadingFactor)")
                    Text("Coding Rate: 4/\(preset.codingRate)")
                }
                .font(.caption)
                .foregroundStyle(MeshTheme.textPrimary)
                .listRowBackground(MeshTheme.surface)

                Button {
                    presetToConfirm = preset
                } label: {
                    HStack {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(MeshTheme.accent)
                            .frame(width: 24)
                        Text("Apply Preset")
                            .foregroundStyle(MeshTheme.accent)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(MeshTheme.surface)
                .alert("Apply Radio Preset?", isPresented: Binding(
                    get: { presetToConfirm != nil },
                    set: { if !$0 { presetToConfirm = nil } }
                )) {
                    Button("Cancel", role: .cancel) { presetToConfirm = nil }
                    Button("Apply") {
                        if let p = presetToConfirm {
                            onApply(p)
                            selectedPresetIndex = -1
                        }
                        presetToConfirm = nil
                    }
                } message: {
                    if let p = presetToConfirm {
                        Text("This will change your radio to \(String(format: "%.3f", p.frequencyKHz / 1000)) MHz, BW \(p.bandwidth == p.bandwidth.rounded() ? "\(Int(p.bandwidth))" : "\(p.bandwidth)") kHz, SF\(p.spreadingFactor), CR 4/\(p.codingRate).\n\nAll nodes on your mesh must use the same settings.")
                    }
                }
            }
        } header: {
            Text("Radio Presets")
                .foregroundStyle(MeshTheme.textSecondary)
        } footer: {
            Text("Select a preset for your region. All nodes on your mesh must use the same settings.")
                .font(.caption2)
        }
    }
}

let radioPresets: [RadioPreset] = [
    // USA / Canada
    RadioPreset(name: "USA/Canada (Recommended)", region: "North America",
                frequencyKHz: 910525.244, bandwidth: 62.5, spreadingFactor: 7, codingRate: 5),
    RadioPreset(name: "USA/Canada (Legacy Wide)", region: "North America",
                frequencyKHz: 915800.0, bandwidth: 250, spreadingFactor: 11, codingRate: 5),
    RadioPreset(name: "USA: Texas", region: "North America",
                frequencyKHz: 903500.0, bandwidth: 62.5, spreadingFactor: 7, codingRate: 5),
    RadioPreset(name: "USA: Southern California", region: "North America",
                frequencyKHz: 927875.0, bandwidth: 62.5, spreadingFactor: 7, codingRate: 8),

    // Australia
    RadioPreset(name: "Australia", region: "Australia/NZ",
                frequencyKHz: 915800.0, bandwidth: 250, spreadingFactor: 10, codingRate: 5),
    RadioPreset(name: "Australia: Victoria", region: "Australia/NZ",
                frequencyKHz: 916575.0, bandwidth: 62.5, spreadingFactor: 7, codingRate: 5),
    RadioPreset(name: "Australia: Brisbane", region: "Australia/NZ",
                frequencyKHz: 917800.0, bandwidth: 62.5, spreadingFactor: 8, codingRate: 5),
    RadioPreset(name: "Australia: Western Australia", region: "Australia/NZ",
                frequencyKHz: 921500.0, bandwidth: 62.5, spreadingFactor: 7, codingRate: 5),

    // New Zealand
    RadioPreset(name: "New Zealand", region: "Australia/NZ",
                frequencyKHz: 915800.0, bandwidth: 250, spreadingFactor: 10, codingRate: 5),
    RadioPreset(name: "New Zealand (Narrow)", region: "Australia/NZ",
                frequencyKHz: 916800.0, bandwidth: 62.5, spreadingFactor: 8, codingRate: 5),

    // Europe / UK
    RadioPreset(name: "Europe (Recommended)", region: "Europe",
                frequencyKHz: 869525.0, bandwidth: 62.5, spreadingFactor: 9, codingRate: 5),
    RadioPreset(name: "Europe (Legacy Wide)", region: "Europe",
                frequencyKHz: 869525.0, bandwidth: 250, spreadingFactor: 11, codingRate: 5),
    RadioPreset(name: "UK", region: "Europe",
                frequencyKHz: 869525.0, bandwidth: 62.5, spreadingFactor: 9, codingRate: 5),
    RadioPreset(name: "Netherlands", region: "Europe",
                frequencyKHz: 869525.0, bandwidth: 62.5, spreadingFactor: 9, codingRate: 5),

    // Asia
    RadioPreset(name: "Thailand", region: "Asia",
                frequencyKHz: 920000.0, bandwidth: 62.5, spreadingFactor: 7, codingRate: 5),
    RadioPreset(name: "Japan", region: "Asia",
                frequencyKHz: 923000.0, bandwidth: 62.5, spreadingFactor: 7, codingRate: 5),
    RadioPreset(name: "India", region: "Asia",
                frequencyKHz: 866000.0, bandwidth: 62.5, spreadingFactor: 7, codingRate: 5),
]

struct RadioSection: View {
    @ObservedObject var viewModel: MeshCoreViewModel
    @State private var freqMHz: String = ""
    @State private var selectedBW: Double = 250
    @State private var selectedSF: UInt8 = 12
    @State private var selectedCR: UInt8 = 5
    @State private var txPower: Double = 22
    @State private var showRepeatConfirm = false
    @State private var repeatMode = false
    @State private var saveState: SaveButtonState = .idle

    var body: some View {
        RadioPresetPicker { preset in
            applyPreset(preset)
            // Send directly to device
            let freq = UInt32(preset.frequencyKHz)
            let bw = UInt32(preset.bandwidth * 1000)
            viewModel.setRadioParams(
                frequency: freq, bandwidth: bw,
                spreadingFactor: preset.spreadingFactor, codingRate: preset.codingRate,
                repeatMode: repeatMode
            )
        }

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
                Slider(value: $txPower, in: 2...Double(max(viewModel.deviceConfig.maxTXPower, 2)), step: 1)
                    .tint(MeshTheme.accent)
            }
            .listRowBackground(MeshTheme.surface)

            Toggle(isOn: Binding(
                get: { repeatMode },
                set: { newValue in
                    if newValue && viewModel.deviceConfig.selfType == 1 {
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
                if viewModel.allowedRepeatFreqRanges.isEmpty {
                    Text("Your companion radio will act as a portable repeater.\n\nThis is useful for camping, hiking, and search & rescue where repeater infrastructure doesn't exist.\n\nRepeat mode is restricted to allowed frequency ranges configured on the device.")
                } else {
                    let freqText = viewModel.allowedRepeatFreqRanges.map { range in
                        String(format: "%.1f\u{2013}%.1f MHz", Double(range.lowerHz) / 1_000_000, Double(range.upperHz) / 1_000_000)
                    }.joined(separator: "\n")
                    Text("Your companion radio will act as a portable repeater.\n\nAllowed frequency ranges:\n\(freqText)\n\nThis is useful for camping, hiking, and search & rescue where repeater infrastructure doesn't exist.")
                }
            }

            SaveButton(state: saveState, label: "Apply Radio Settings") {
                let freq = UInt32((Double(freqMHz) ?? 0) * 1000)
                let bw = UInt32(selectedBW * 1000)
                viewModel.setRadioParams(
                    frequency: freq, bandwidth: bw,
                    spreadingFactor: selectedSF, codingRate: selectedCR,
                    repeatMode: repeatMode
                )
                viewModel.setRadioTXPower(UInt8(txPower))
                showSaved($saveState)
            }

            if !viewModel.allowedRepeatFreqRanges.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "waveform.badge.magnifyingglass")
                                .foregroundStyle(MeshTheme.accent)
                                .frame(width: 24)
                            Text("Allowed Repeat Frequencies")
                                .foregroundStyle(MeshTheme.accent)
                        }
                        ForEach(Array(viewModel.allowedRepeatFreqRanges.enumerated()), id: \.offset) { _, range in
                            Text("\(String(format: "%.3f", Double(range.lowerHz) / 1_000_000)) \u{2013} \(String(format: "%.3f", Double(range.upperHz) / 1_000_000)) MHz")
                                .font(.caption)
                                .foregroundStyle(MeshTheme.textPrimary)
                                .padding(.leading, 32)
                        }
                    }
                    .listRowBackground(MeshTheme.surface)
                }

                Button {
                    viewModel.requestAllowedRepeatFreq()
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
            Text("Radio Configuration")
                .foregroundStyle(MeshTheme.textSecondary)
        } footer: {
            Text("All radios on your mesh must use the same settings. SF (Spreading Factor): higher = longer range, slower. CR (Coding Rate): higher = more error correction. BW (Bandwidth): lower = longer range. Changes require reboot.")
                .font(.caption2)
        }
        .onAppear { loadFromConfig() }
        .onChange(of: viewModel.deviceConfig.radioFrequency) { _ in loadFromConfig() }
    }

    private func loadFromConfig() {
        let c = viewModel.deviceConfig
        freqMHz = c.radioFrequency == 0 ? "" : String(format: "%.3f", c.frequencyMHz)
        selectedBW = nearestBW(c.bandwidthKHz)
        selectedSF = c.radioSpreadingFactor
        selectedCR = c.radioCodingRate
        txPower = Double(c.radioTXPower)
        repeatMode = c.repeatMode
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

// MARK: - Section 5: Tuning Parameters (Fix #7: populate values)

private extension SettingsView {
    var tuningSection: some View {
        TuningSection(viewModel: viewModel)
    }
}

struct TuningSection: View {
    @ObservedObject var viewModel: MeshCoreViewModel
    @State private var rxDelay: String = ""
    @State private var airtime: String = ""
    @State private var saveState: SaveButtonState = .idle

    @State private var isExpanded = false

    var body: some View {
        // Tuning parameters
        Section {
            DisclosureGroup(isExpanded: $isExpanded) {
                HStack {
                    Image(systemName: "timer")
                        .foregroundStyle(MeshTheme.accent)
                        .frame(width: 24)
                    Text("RX Delay Base (s)")
                        .foregroundStyle(MeshTheme.accent)
                    Spacer()
                    #if os(watchOS)
                    TextField("seconds", text: $rxDelay)
                        .foregroundStyle(MeshTheme.textPrimary)
                        .frame(width: 80)
                    #else
                    TextField("seconds", text: $rxDelay)
                        .foregroundStyle(MeshTheme.textPrimary)
                        .textFieldStyle(MeshTextFieldStyle())
                        .frame(width: 100)
                    #endif
                }

                HStack {
                    Image(systemName: "clock.arrow.2.circlepath")
                        .foregroundStyle(MeshTheme.accent)
                        .frame(width: 24)
                    Text("Airtime Factor")
                        .foregroundStyle(MeshTheme.accent)
                    Spacer()
                    #if os(watchOS)
                    TextField("multiplier", text: $airtime)
                        .foregroundStyle(MeshTheme.textPrimary)
                        .frame(width: 80)
                    #else
                    TextField("multiplier", text: $airtime)
                        .foregroundStyle(MeshTheme.textPrimary)
                        .textFieldStyle(MeshTextFieldStyle())
                        .frame(width: 100)
                    #endif
                }

                SaveButton(state: saveState, label: "Apply Tuning") {
                    let rx = UInt32((Double(rxDelay) ?? 0) * 1000)
                    let at = UInt32((Double(airtime) ?? 0) * 1000)
                    viewModel.setTuningParams(rxDelayBase: rx, airtimeFactor: at)
                    showSaved($saveState)
                }
            } label: {
                Label("Tuning Parameters", systemImage: "slider.horizontal.3")
                    .foregroundStyle(MeshTheme.accent)
            }
            .listRowBackground(MeshTheme.surface)
        } footer: {
            Text("Advanced — adjust timing parameters for mesh performance. Default values work well for most setups.")
                .font(.caption2)
        }
        .onAppear { loadFromConfig() }
        .onChange(of: viewModel.deviceConfig.rxDelayBase) { _ in loadFromConfig() }
    }

    private func loadFromConfig() {
        let c = viewModel.deviceConfig
        rxDelay = c.rxDelayBase == 0 ? "0" : String(format: "%.1f", c.rxDelaySeconds)
        airtime = c.airtimeFactor == 0 ? "0" : String(format: "%.1f", c.airtimeMultiplier)
    }
}

// MARK: - Section 6: Privacy & Security (Fix #8: telemetry pickers)

private extension SettingsView {
    var privacySection: some View {
        PrivacySection(viewModel: viewModel)
    }
}

struct PrivacySection: View {
    @ObservedObject var viewModel: MeshCoreViewModel
    @State private var manualAdd: Bool = false
    @State private var telBase: UInt8 = 0
    @State private var telLoc: UInt8 = 0
    @State private var advertLoc: Bool = false
    @State private var multiACK: Bool = false
    @State private var pinText: String = ""
    @State private var suppressReadback = false
    @State private var saveState: SaveButtonState = .idle
    @State private var autoAddChat: Bool = true
    @State private var autoAddRepeater: Bool = true
    @State private var autoAddRoom: Bool = true
    @State private var autoAddSensor: Bool = true
    @AppStorage("locationPrivacyRadius") private var locationPrivacyRadius: Double = 0

    var body: some View {
        Section {
            Toggle(isOn: $manualAdd) {
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

            if !manualAdd {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Auto-Add Contact Types")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                    Toggle("Chat Users", isOn: $autoAddChat)
                        .tint(MeshTheme.accent)
                        .onChange(of: autoAddChat) { _ in saveAutoAddConfig() }
                    Toggle("Repeaters", isOn: $autoAddRepeater)
                        .tint(MeshTheme.accent)
                        .onChange(of: autoAddRepeater) { _ in saveAutoAddConfig() }
                    Toggle("Room Servers", isOn: $autoAddRoom)
                        .tint(MeshTheme.accent)
                        .onChange(of: autoAddRoom) { _ in saveAutoAddConfig() }
                    Toggle("Sensors", isOn: $autoAddSensor)
                        .tint(MeshTheme.accent)
                        .onChange(of: autoAddSensor) { _ in saveAutoAddConfig() }
                }
                .listRowBackground(MeshTheme.surface)
            }

            HStack {
                Image(systemName: "battery.100")
                    .foregroundStyle(MeshTheme.accent)
                    .frame(width: 24)
                Picker("Telemetry Requests", selection: $telBase) {
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
                Picker("Include Location", selection: $telLoc) {
                    Text("Deny").tag(UInt8(0))
                    Text("Per-Contact").tag(UInt8(1))
                    Text("Allow All").tag(UInt8(2))
                }
                .foregroundStyle(MeshTheme.accent)
                .tint(MeshTheme.accent)
            }
            .listRowBackground(MeshTheme.surface)

            Toggle(isOn: $advertLoc) {
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

            Toggle(isOn: $multiACK) {
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

            SaveButton(state: saveState, label: "Save Privacy Settings") {
                suppressReadback = true
                viewModel.setOtherParams(
                    manualAddContacts: manualAdd ? 1 : 0,
                    telemetryBase: telBase,
                    telemetryLocation: telLoc,
                    advertLocPolicy: advertLoc ? 1 : 0,
                    multiACK: multiACK ? 1 : 0
                )
                showSaved($saveState)
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    suppressReadback = false
                }
            }
        } header: {
            Text("Privacy & Security")
                .foregroundStyle(MeshTheme.textSecondary)
        } footer: {
            Text("Controls what telemetry data is shared when requested. Per-Contact mode only shares with contacts that have telemetry permission set. Position Accuracy adds a random offset to your personal device location only. Repeater and room server locations are always shared at exact coordinates for accurate mesh routing.")
                .font(.caption2)
        }

        // Per-contact telemetry permission picker
        if telBase == 1 {
            Section {
                let chatContacts = viewModel.contacts.filter { $0.type == .chat }
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
                                viewModel.updateContactFlags(contact, newFlags: newFlags)
                            }
                        )) {
                            Text(viewModel.displayName(for: contact))
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
                let count = viewModel.contacts.filter { $0.type == .chat && $0.allowTelemetry }.count
                Text("\(count) contact\(count == 1 ? "" : "s") can request your telemetry data.")
                    .font(.caption2)
            }
        }

        // Per-contact location permission picker
        if telLoc == 1 {
            Section {
                let chatContacts = viewModel.contacts.filter { $0.type == .chat }
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
                                viewModel.updateContactFlags(contact, newFlags: newFlags)
                            }
                        )) {
                            Text(viewModel.displayName(for: contact))
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
                let count = viewModel.contacts.filter { $0.type == .chat && $0.shareTelemetryLocation }.count
                Text("\(count) contact\(count == 1 ? "" : "s") will receive your location in telemetry.")
                    .font(.caption2)
            }
        }

        // BLE PIN — adaptive based on whether device has a screen
        Section {
            if viewModel.deviceConfig.blePIN == 0 {
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
                        viewModel.setDevicePIN(1)
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            viewModel.refreshAllSettings()
                        }
                    } label: {
                        Label("Randomize", systemImage: "dice")
                            .foregroundStyle(MeshTheme.accent)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        if let pin = UInt32(pinText) {
                            viewModel.setDevicePIN(pin)
                        }
                    } label: {
                        Text("Apply")
                            .foregroundStyle(MeshTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(pinText.isEmpty || UInt32(pinText) == nil)
                }
                .listRowBackground(MeshTheme.surface)
            }
        } header: {
            Text("Bluetooth Security")
                .foregroundStyle(MeshTheme.textSecondary)
        } footer: {
            if viewModel.deviceConfig.blePIN == 0 {
                Text("This device generates a random PIN each time it starts. Check the device screen for the current PIN when pairing.")
                    .font(.caption2)
            } else {
                Text("Change the BLE PIN from the default (123456) for security. After changing, forget this device in Bluetooth settings and re-pair with the new PIN.")
                    .font(.caption2)
            }
        }
        .onAppear { loadFromConfig() }
        .onChange(of: viewModel.deviceConfig.manualAddContacts) { _ in loadFromConfig() }
        .onChange(of: viewModel.deviceConfig.blePIN) { _ in pinText = String(viewModel.deviceConfig.blePIN) }
        .onChange(of: locationPrivacyRadius) { _ in
            MeshCoreViewModel.regenerateLocationFudge()
        }
    }

    private func loadFromConfig() {
        guard !suppressReadback else { return }
        let c = viewModel.deviceConfig
        manualAdd = c.manualAddContacts != 0
        telBase = c.telemetryBase
        telLoc = c.telemetryLocation
        advertLoc = c.advertLocPolicy != 0
        multiACK = c.multiACK != 0
        pinText = String(c.blePIN)
        let bm = c.autoAddBitmask
        autoAddChat = bm & 0x01 != 0
        autoAddRepeater = bm & 0x02 != 0
        autoAddRoom = bm & 0x04 != 0
        autoAddSensor = bm & 0x08 != 0
    }

    private func saveAutoAddConfig() {
        var bitmask: UInt8 = 0
        if autoAddChat { bitmask |= 0x01 }
        if autoAddRepeater { bitmask |= 0x02 }
        if autoAddRoom { bitmask |= 0x04 }
        if autoAddSensor { bitmask |= 0x08 }
        viewModel.setAutoAddConfig(bitmask: bitmask)
    }
}

// MARK: - Section 7: Time

private extension SettingsView {
    var timeSection: some View {
        Section {
            HStack {
                Image(systemName: "clock")
                    .foregroundStyle(MeshTheme.accent)
                    .frame(width: 24)
                Text("Device Time")
                    .foregroundStyle(MeshTheme.accent)
                Spacer()
                Text(deviceTimeString)
                    .foregroundStyle(MeshTheme.textPrimary)
                    .font(.caption)
            }
            .listRowBackground(MeshTheme.surface)

            if let deviceDate = config.deviceTimeDate, abs(deviceDate.timeIntervalSince(Date())) > 86400 {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Device clock is off by more than 24 hours. Tap \u{2018}Sync Device Clock\u{2019} to fix.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .listRowBackground(MeshTheme.surface)
            }

            Button {
                let epoch = UInt32(Date().timeIntervalSince1970)
                viewModel.setDeviceTime(epochSeconds: epoch)
                clockSynced = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { clockSynced = false }
            } label: {
                HStack {
                    Image(systemName: clockSynced ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                        .foregroundStyle(clockSynced ? MeshTheme.connected : MeshTheme.accent)
                        .frame(width: 24)
                    Text(clockSynced ? "Clock Synced" : "Sync Device Clock")
                        .foregroundStyle(clockSynced ? MeshTheme.connected : MeshTheme.accent)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(MeshTheme.surface)
        } header: {
            sectionHeader("Time")
        }
    }

    var deviceTimeString: String {
        guard let date = config.deviceTimeDate else { return "\u{2014}" }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .medium
        return fmt.string(from: date)
    }
}

// MARK: - Section 8: Custom Variables

private extension SettingsView {
    var customVarsSection: some View {
        CustomVarsSection(viewModel: viewModel)
    }
}

struct CustomVarsSection: View {
    @ObservedObject var viewModel: MeshCoreViewModel
    @State private var newName: String = ""
    @State private var newValue: String = ""

    var body: some View {
        Section {
            ForEach(Array(viewModel.deviceConfig.customVars.enumerated()), id: \.offset) { _, pair in
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
                    viewModel.setCustomVar(name: newName, value: newValue)
                    newName = ""
                    newValue = ""
                    Task {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        viewModel.requestCustomVars()
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
            Text("Custom Variables")
                .foregroundStyle(MeshTheme.textSecondary)
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
                infoRow(icon: "antenna.radiowaves.left.and.right", label: "Last SNR", value: String(format: "%.1f dB", Double(config.statsLastSNR) / 4.0))
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
                    viewModel.requestStats(subType: 0)
                    viewModel.requestStats(subType: 1)
                    viewModel.requestStats(subType: 2)
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

// MARK: - App Security

private extension SettingsView {
    var securitySection: some View {
        Section {
            Toggle(isOn: appLockBinding) {
                Label("App Lock", systemImage: biometricIcon)
                    .foregroundStyle(MeshTheme.accent)
            }
            .tint(MeshTheme.accent)
            .listRowBackground(MeshTheme.surface)
        } header: {
            sectionHeader("Security")
        } footer: {
            Text("When enabled, Face ID, Touch ID, or your device passcode is required to open MeshCore.")
                .font(.caption2)
        }
    }

    private var appLockBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: "appLockEnabled") },
            set: { newValue in
                if newValue {
                    // Verify authentication works before enabling
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

// MARK: - Tip Jar

@MainActor
class TipJarManager: ObservableObject {
    @Published var products: [Product] = []
    @Published var purchaseSuccess = false
    @Published var isLoading = false
    @Published var purchasingProductID: String?

    private var hasLoaded = false

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
        guard !hasLoaded && !isLoading else { return }
        isLoading = true
        hasLoaded = true

        let ids = Set(Self.productIDs)
        DebugLogger.shared.log("TIP JAR: requesting \(ids.count) products: \(ids.joined(separator: ", "))", level: .info)

        Task.detached {
            let loaded: [Product]
            do {
                let fetched = try await Product.products(for: ids)
                loaded = fetched.sorted { $0.price < $1.price }
                for p in loaded {
                    DebugLogger.shared.log("TIP JAR: product \(p.id) — \(p.displayPrice)", level: .info)
                }
                DebugLogger.shared.log("TIP JAR: loaded \(loaded.count) products", level: .info)
            } catch {
                DebugLogger.shared.log("TIP JAR: ERROR loading — \(error.localizedDescription)", level: .error)
                loaded = []
            }
            await MainActor.run {
                self.products = loaded
                self.isLoading = false
            }
        }
    }

    @MainActor
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
                    self.purchaseSuccess = true
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

private extension SettingsView {
    var storageSection: some View {
        Section {
            Button {
                showPurgeOptions = true
            } label: {
                HStack {
                    Label("Manage Storage", systemImage: "externaldrive")
                        .foregroundStyle(MeshTheme.accent)
                    Spacer()
                    let count = viewModel.messagesByContact.values.reduce(0) { $0 + $1.count }
                    Text("\(count) messages")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                }
            }
            .buttonStyle(.plain)
            .listRowBackground(MeshTheme.surface)
            .confirmationDialog("Manage Storage", isPresented: $showPurgeOptions) {
                Button("Clear All Messages", role: .destructive) {
                    viewModel.clearAllMessages()
                }
                Button("Clear Message Drafts") {
                    viewModel.clearAllDrafts()
                }
                Button("Cancel", role: .cancel) {}
            }
        } header: {
            sectionHeader("Storage")
        }
    }

    var tipJarSection: some View {
        Section {
            NavigationLink {
                TipJarView(manager: tipJar)
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
            }
            .listRowBackground(MeshTheme.surface)
        } header: {
            sectionHeader("Support")
        }
    }

    private func tipEmoji(for product: Product) -> String {
        if product.id.hasSuffix(".decent") { return "\u{1F44B}" }
        if product.id.hasSuffix(".nice") { return "\u{1F44D}" }
        if product.id.hasSuffix(".great") { return "\u{1F389}" }
        if product.id.hasSuffix(".help") { return "\u{1F49A}" }
        return "\u{2764}\u{FE0F}"
    }
}

/// MARK: - Tip Jar Standalone View (outside List hierarchy)

struct TipJarView: View {
    @ObservedObject var manager: TipJarManager

    var body: some View {
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
                    Text("Products unavailable")
                        .foregroundStyle(MeshTheme.textSecondary)
                        .padding()
                } else {
                    ForEach(manager.products) { product in
                        TipButton(product: product, manager: manager)
                    }
                }

                if manager.purchaseSuccess {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(MeshTheme.connected)
                        Text("Thank you for your support!")
                            .foregroundStyle(MeshTheme.connected)
                    }
                    .padding()
                }
            }
            .padding()
        }
        .background(MeshTheme.background)
        .navigationTitle("Tip Jar")
        #if !os(macOS)
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
            HStack {
                Text("App Version")
                    .foregroundStyle(MeshTheme.accent)
                Spacer()
                Text("\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                    .foregroundStyle(MeshTheme.textPrimary)
            }
            .listRowBackground(MeshTheme.surface)

            if isConnected, !config.semanticVersion.isEmpty {
                HStack {
                    Text("Firmware")
                        .foregroundStyle(MeshTheme.accent)
                    Spacer()
                    Text(config.semanticVersion)
                        .foregroundStyle(MeshTheme.textPrimary)
                }
                .listRowBackground(MeshTheme.surface)
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
            }
            .buttonStyle(.plain)
            .listRowBackground(MeshTheme.surface)

            Button {
                viewModel.verifyRadioConfig()
            } label: {
                HStack {
                    Text("Verify Radio Config")
                        .foregroundStyle(MeshTheme.accent)
                    Spacer()
                    if viewModel.isVerifyingConfig {
                        ProgressView()
                            #if !os(watchOS)
                            .controlSize(.small)
                            #endif
                    } else {
                        Image(systemName: "checkmark.shield")
                            .foregroundStyle(MeshTheme.textSecondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!isConnected || viewModel.isVerifyingConfig)
            .listRowBackground(MeshTheme.surface)

            if let result = viewModel.lastConfigVerification {
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
        } header: {
            sectionHeader("About")
        }
    }
}

// MARK: - Section 10: Danger Zone (Fix #13: Factory Reset requires typing RESET)

private extension SettingsView {
    var dangerZoneSection: some View {
        DangerZoneSection(viewModel: viewModel)
    }
}

struct DangerZoneSection: View {
    @ObservedObject var viewModel: MeshCoreViewModel
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
                    viewModel.rebootDevice()
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
                        viewModel.factoryReset()
                    }
                }
                .disabled(resetConfirmText != "RESET")
            } message: {
                Text("Are you sure? This will erase all device settings, contacts, and messages. This cannot be undone.\n\nType RESET to confirm.")
            }
        } header: {
            Text("Danger Zone")
                .foregroundStyle(.red)
        } footer: {
            Text("Factory reset erases all contacts, channels, settings, and encryption keys from the device. This cannot be undone.")
                .font(.caption2)
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
    var config: DeviceConfig { viewModel.deviceConfig }

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
}
