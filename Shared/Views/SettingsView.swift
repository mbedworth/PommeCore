import SwiftUI
import MeshCoreKit

struct SettingsView: View {
    @EnvironmentObject var viewModel: MeshCoreViewModel
    @AppStorage("batteryChemistry") private var batteryChemistryRaw: String = BatteryChemistry.lipo.rawValue
    @AppStorage("appTheme") private var appTheme: String = AppTheme.system.rawValue
    @State private var statsExpanded = false

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

            aboutSection
        }
        .meshListStyle()
    }

    // MARK: - Settings Form

    private var settingsForm: some View {
        List {
            appearanceSection
            notificationsSection
            deviceInfoSection
            connectionSection
            identitySection
            radioSection
            tuningSection
            privacySection
            timeSection
            if !viewModel.deviceConfig.customVars.isEmpty {
                customVarsSection
            }
            statsSection
            aboutSection
            dangerZoneSection
        }
        .meshListStyle()
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
    @AppStorage("notifyDirectMessages") private var notifyDirect = true
    @AppStorage("notifyChannelMessages") private var notifyChannel = true
    @AppStorage("notifyRoomServerMessages") private var notifyRoom = true
    @AppStorage("notifyNewContacts") private var notifyNewContacts = false
    @AppStorage("notifyConnectionChanges") private var notifyConnection = true

    var body: some View {
        Section {
            Toggle(isOn: $notifyDirect) {
                Label("Direct Messages", systemImage: "bubble.left.fill")
                    .foregroundStyle(MeshTheme.accent)
            }
            .tint(MeshTheme.accent)
            .listRowBackground(MeshTheme.surface)

            Toggle(isOn: $notifyChannel) {
                Label("Channel Messages", systemImage: "number")
                    .foregroundStyle(MeshTheme.accent)
            }
            .tint(MeshTheme.accent)
            .listRowBackground(MeshTheme.surface)

            Toggle(isOn: $notifyRoom) {
                Label("Room Server Messages", systemImage: "server.rack")
                    .foregroundStyle(MeshTheme.accent)
            }
            .tint(MeshTheme.accent)
            .listRowBackground(MeshTheme.surface)

            Toggle(isOn: $notifyNewContacts) {
                Label("New Contacts Discovered", systemImage: "person.badge.plus")
                    .foregroundStyle(MeshTheme.accent)
            }
            .tint(MeshTheme.accent)
            .listRowBackground(MeshTheme.surface)

            Toggle(isOn: $notifyConnection) {
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

// MARK: - Section 1: Device Info

private extension SettingsView {
    var deviceInfoSection: some View {
        Section {
            infoRow(icon: "tag", label: "Name", value: config.deviceName.isEmpty ? (viewModel.connectedDeviceName ?? "\u{2014}") : config.deviceName)
            infoRow(icon: "cpu", label: "Firmware Ver", value: config.firmwareVersion.isEmpty || config.firmwareVersion == "0" ? "\u{2014}" : "v\(config.firmwareVersion)")
            infoRow(icon: "calendar", label: "Build Date", value: config.buildDate.isEmpty ? "\u{2014}" : config.buildDate)
            infoRow(icon: "building.2", label: "Model", value: config.manufacturer.isEmpty ? "\u{2014}" : config.manufacturer)
            infoRow(icon: "number", label: "Version", value: config.semanticVersion.isEmpty ? "\u{2014}" : config.semanticVersion)
            if config.maxContacts > 0 {
                infoRow(icon: "person.2", label: "Contacts", value: "\(viewModel.contacts.count) / \(config.maxContacts)")
            }
            if config.maxChannels > 0 {
                infoRow(icon: "number.circle", label: "Channels", value: "\(viewModel.channels.count) / \(config.maxChannels)")
            }
            if !config.publicKeyHex.isEmpty {
                publicKeyRow
            }
            batteryRow
            batteryChemistryPicker
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
        }
        .listRowBackground(MeshTheme.surface)
    }

    var statsBatteryDisplay: String {
        guard config.statsBatteryMV != 0 else { return "\u{2014}" }
        let mv = Int(config.statsBatteryMV)
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

    var batteryRow: some View {
        HStack {
            Image(systemName: batteryIconName)
                .foregroundStyle(batteryColor)
                .frame(width: 24)
            Text("Battery")
                .foregroundStyle(MeshTheme.accent)
            Spacer()
            if config.batteryMillivolts > 0 {
                Text("\(String(format: "%.2fV", config.batteryVoltage)) (\(config.batteryPercent(chemistry: batteryChemistry))%)")
                    .foregroundStyle(MeshTheme.textPrimary)
            } else {
                Text("\u{2014}")
                    .foregroundStyle(MeshTheme.textSecondary)
            }
        }
        .listRowBackground(MeshTheme.surface)
    }

    var batteryIconName: String {
        let pct = config.batteryPercent(chemistry: batteryChemistry)
        if pct > 75 { return "battery.100" }
        if pct > 50 { return "battery.75" }
        if pct > 25 { return "battery.50" }
        if pct > 0 { return "battery.25" }
        return "battery.0"
    }

    var batteryColor: Color {
        let pct = config.batteryPercent(chemistry: batteryChemistry)
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
                    viewModel.sendAdvertise(type: 0)
                } label: {
                    Label("Advertise", systemImage: "dot.radiowaves.left.and.right")
                        .foregroundStyle(MeshTheme.accent)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
            .listRowBackground(MeshTheme.surface)
        } header: {
            Text("Identity & Advertising")
                .foregroundStyle(MeshTheme.textSecondary)
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
                Text("Your companion radio will act as a portable repeater.\n\nThis is useful for camping, hiking, and search & rescue where repeater infrastructure doesn't exist.\n\nRepeat mode is restricted to allowed frequency ranges configured on the device.")
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
            Text("Changing radio parameters will disconnect you from nodes using different settings. All nodes on your mesh must use the same frequency, bandwidth, spreading factor, and coding rate.")
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
    @State private var saveState: SaveButtonState = .idle

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

            SaveButton(state: saveState, label: "Save Privacy Settings") {
                viewModel.setOtherParams(
                    manualAddContacts: manualAdd ? 1 : 0,
                    telemetryBase: telBase,
                    telemetryLocation: telLoc,
                    advertLocPolicy: advertLoc ? 1 : 0,
                    multiACK: multiACK ? 1 : 0
                )
                showSaved($saveState)
            }
        } header: {
            Text("Privacy & Security")
                .foregroundStyle(MeshTheme.textSecondary)
        } footer: {
            Text("Controls what telemetry data is shared when requested. Per-Contact mode only shares with contacts that have telemetry permission set.")
                .font(.caption2)
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
    }

    private func loadFromConfig() {
        let c = viewModel.deviceConfig
        manualAdd = c.manualAddContacts != 0
        telBase = c.telemetryBase
        telLoc = c.telemetryLocation
        advertLoc = c.advertLocPolicy != 0
        multiACK = c.multiACK != 0
        pinText = String(c.blePIN)
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

            Button {
                let epoch = UInt32(Date().timeIntervalSince1970)
                viewModel.setDeviceTime(epochSeconds: epoch)
            } label: {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(MeshTheme.accent)
                        .frame(width: 24)
                    Text("Sync Device Clock")
                        .foregroundStyle(MeshTheme.accent)
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
        }
        .listRowBackground(MeshTheme.surface)
    }

    func sectionHeader(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(MeshTheme.textSecondary)
    }
}
