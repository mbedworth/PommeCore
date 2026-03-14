import SwiftUI
import MeshCoreKit

struct SettingsView: View {
    @EnvironmentObject var viewModel: MeshCoreViewModel

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
        VStack(spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 48))
                .foregroundStyle(MeshTheme.textSecondary)
            Text("No device connected")
                .foregroundStyle(MeshTheme.textSecondary)
            Text("Connect to a MeshCore device to view settings.")
                .font(.caption)
                .foregroundStyle(MeshTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MeshTheme.background)
    }

    // MARK: - Settings Form

    private var settingsForm: some View {
        List {
            deviceInfoSection
            connectionSection
            identitySection
            radioSection
            tuningSection
            privacySection
            timeSection
            customVarsSection
            statsSection
            dangerZoneSection
        }
        .meshListStyle()
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    viewModel.refreshAllSettings()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(MeshTheme.accentFallback)
                }
                .help("Refresh all settings")
            }
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
                infoRow(icon: "person.2", label: "Max Contacts", value: "\(config.maxContacts)")
            }
            if config.maxChannels > 0 {
                infoRow(icon: "number.circle", label: "Max Channels", value: "\(config.maxChannels)")
            }
            if !config.publicKeyHex.isEmpty {
                publicKeyRow
            }
            batteryRow
        } header: {
            sectionHeader("Device Info")
        }
    }

    // Fix #11: Public key with Copy button
    var publicKeyRow: some View {
        HStack {
            Image(systemName: "key")
                .foregroundStyle(MeshTheme.accentFallback)
                .frame(width: 24)
            Text("Public Key")
                .foregroundStyle(MeshTheme.textPrimary)
            Spacer()
            Text(String(config.publicKeyHex.prefix(16)) + "...")
                .foregroundStyle(MeshTheme.textSecondary)
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
                    .foregroundStyle(MeshTheme.accentFallback)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
        .listRowBackground(MeshTheme.surface)
    }

    // Fix #9: Battery with percentage, icon, and color
    var batteryRow: some View {
        HStack {
            Image(systemName: batteryIconName)
                .foregroundStyle(batteryColor)
                .frame(width: 24)
            Text("Battery")
                .foregroundStyle(MeshTheme.textPrimary)
            Spacer()
            if config.batteryMillivolts > 0 {
                Text("\(String(format: "%.2fV", config.batteryVoltage))  \(config.batteryPercent)%")
                    .foregroundStyle(MeshTheme.textSecondary)
            } else {
                Text("\u{2014}")
                    .foregroundStyle(MeshTheme.textSecondary)
            }
        }
        .listRowBackground(MeshTheme.surface)
    }

    var batteryIconName: String {
        let pct = config.batteryPercent
        if pct > 75 { return "battery.100" }
        if pct > 50 { return "battery.75" }
        if pct > 25 { return "battery.50" }
        if pct > 0 { return "battery.25" }
        return "battery.0"
    }

    var batteryColor: Color {
        let pct = config.batteryPercent
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
                    .foregroundStyle(MeshTheme.textPrimary)
                Spacer()
                Text(connectionLabel)
                    .foregroundStyle(MeshTheme.textSecondary)
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
                    .foregroundStyle(MeshTheme.accentFallback)
                    .frame(width: 24)
                #if os(watchOS)
                TextField("Advert Name", text: $advertName)
                    .foregroundStyle(MeshTheme.textPrimary)
                #else
                TextField("Advert Name", text: $advertName)
                    .foregroundStyle(MeshTheme.textPrimary)
                    .textFieldStyle(.roundedBorder)
                #endif
            }
            .listRowBackground(MeshTheme.surface)

            HStack {
                Image(systemName: "location")
                    .foregroundStyle(MeshTheme.accentFallback)
                    .frame(width: 24)
                #if os(watchOS)
                TextField("Latitude", text: $latitude)
                    .foregroundStyle(MeshTheme.textPrimary)
                TextField("Longitude", text: $longitude)
                    .foregroundStyle(MeshTheme.textPrimary)
                #else
                TextField("Latitude", text: $latitude)
                    .foregroundStyle(MeshTheme.textPrimary)
                    .textFieldStyle(.roundedBorder)
                TextField("Longitude", text: $longitude)
                    .foregroundStyle(MeshTheme.textPrimary)
                    .textFieldStyle(.roundedBorder)
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
                        .foregroundStyle(MeshTheme.accentFallback)
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

struct RadioSection: View {
    @ObservedObject var viewModel: MeshCoreViewModel
    @State private var freqMHz: String = ""
    @State private var selectedBW: Double = 250
    @State private var selectedSF: UInt8 = 12
    @State private var selectedCR: UInt8 = 5
    @State private var txPower: Double = 22
    @State private var repeatMode = false
    @State private var saveState: SaveButtonState = .idle

    var body: some View {
        Section {
            // Fix #6: Frequency with 3 decimal places
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(MeshTheme.accentFallback)
                    .frame(width: 24)
                Text("Frequency (MHz)")
                    .foregroundStyle(MeshTheme.textPrimary)
                Spacer()
                #if os(watchOS)
                TextField("MHz", text: $freqMHz)
                    .foregroundStyle(MeshTheme.textPrimary)
                    .frame(width: 80)
                #else
                TextField("MHz", text: $freqMHz)
                    .foregroundStyle(MeshTheme.textPrimary)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                #endif
            }
            .listRowBackground(MeshTheme.surface)

            // Fix #5: Bandwidth picker with standard LoRa values
            HStack {
                Image(systemName: "waveform")
                    .foregroundStyle(MeshTheme.accentFallback)
                    .frame(width: 24)
                Picker("Bandwidth", selection: $selectedBW) {
                    ForEach(loraBandwidths, id: \.self) { bw in
                        Text(formatBW(bw)).tag(bw)
                    }
                }
                .foregroundStyle(MeshTheme.textPrimary)
                .tint(MeshTheme.accentFallback)
            }
            .listRowBackground(MeshTheme.surface)

            // Fix #4: Spreading Factor picker
            HStack {
                Image(systemName: "chart.bar")
                    .foregroundStyle(MeshTheme.accentFallback)
                    .frame(width: 24)
                Picker("Spreading Factor", selection: $selectedSF) {
                    ForEach(Array(UInt8(7)...UInt8(12)), id: \.self) { val in
                        Text("SF\(val)").tag(val)
                    }
                }
                .foregroundStyle(MeshTheme.textPrimary)
                .tint(MeshTheme.accentFallback)
            }
            .listRowBackground(MeshTheme.surface)

            // Fix #3: Coding Rate picker
            HStack {
                Image(systemName: "shield")
                    .foregroundStyle(MeshTheme.accentFallback)
                    .frame(width: 24)
                Picker("Coding Rate", selection: $selectedCR) {
                    Text("4/5").tag(UInt8(5))
                    Text("4/6").tag(UInt8(6))
                    Text("4/7").tag(UInt8(7))
                    Text("4/8").tag(UInt8(8))
                }
                .foregroundStyle(MeshTheme.textPrimary)
                .tint(MeshTheme.accentFallback)
            }
            .listRowBackground(MeshTheme.surface)

            VStack(alignment: .leading) {
                HStack {
                    Image(systemName: "bolt")
                        .foregroundStyle(MeshTheme.accentFallback)
                        .frame(width: 24)
                    Text("TX Power: \(Int(txPower)) dBm")
                        .foregroundStyle(MeshTheme.textPrimary)
                }
                Slider(value: $txPower, in: 2...Double(max(viewModel.deviceConfig.maxTXPower, 2)), step: 1)
                    .tint(MeshTheme.accentFallback)
            }
            .listRowBackground(MeshTheme.surface)

            Toggle(isOn: $repeatMode) {
                HStack {
                    Image(systemName: "repeat")
                        .foregroundStyle(MeshTheme.accentFallback)
                        .frame(width: 24)
                    Text("Repeat Mode")
                        .foregroundStyle(MeshTheme.textPrimary)
                }
            }
            .tint(MeshTheme.accentFallback)
            .listRowBackground(MeshTheme.surface)

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
        } header: {
            Text("Radio Configuration")
                .foregroundStyle(MeshTheme.textSecondary)
        } footer: {
            // Fix #12: Section footer
            Text("Warning: Changing radio parameters will disconnect you from other nodes using different settings.")
                .foregroundStyle(MeshTheme.textSecondary)
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

    var body: some View {
        Section {
            HStack {
                Image(systemName: "timer")
                    .foregroundStyle(MeshTheme.accentFallback)
                    .frame(width: 24)
                Text("RX Delay Base (s)")
                    .foregroundStyle(MeshTheme.textPrimary)
                Spacer()
                #if os(watchOS)
                TextField("seconds", text: $rxDelay)
                    .foregroundStyle(MeshTheme.textPrimary)
                    .frame(width: 80)
                #else
                TextField("seconds", text: $rxDelay)
                    .foregroundStyle(MeshTheme.textPrimary)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                #endif
            }
            .listRowBackground(MeshTheme.surface)

            HStack {
                Image(systemName: "clock.arrow.2.circlepath")
                    .foregroundStyle(MeshTheme.accentFallback)
                    .frame(width: 24)
                Text("Airtime Factor")
                    .foregroundStyle(MeshTheme.textPrimary)
                Spacer()
                #if os(watchOS)
                TextField("multiplier", text: $airtime)
                    .foregroundStyle(MeshTheme.textPrimary)
                    .frame(width: 80)
                #else
                TextField("multiplier", text: $airtime)
                    .foregroundStyle(MeshTheme.textPrimary)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                #endif
            }
            .listRowBackground(MeshTheme.surface)

            SaveButton(state: saveState, label: "Apply Tuning") {
                let rx = UInt32((Double(rxDelay) ?? 0) * 1000)
                let at = UInt32((Double(airtime) ?? 0) * 1000)
                viewModel.setTuningParams(rxDelayBase: rx, airtimeFactor: at)
                showSaved($saveState)
            }
        } header: {
            Text("Tuning Parameters")
                .foregroundStyle(MeshTheme.textSecondary)
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

    private let telemetryOptions: [(UInt8, String)] = [
        (0, "Deny"),
        (1, "Per-Contact"),
        (2, "Allow All"),
    ]

    var body: some View {
        Section {
            Toggle(isOn: $manualAdd) {
                HStack {
                    Image(systemName: "person.badge.plus")
                        .foregroundStyle(MeshTheme.accentFallback)
                        .frame(width: 24)
                    Text("Manual Add Contacts")
                        .foregroundStyle(MeshTheme.textPrimary)
                }
            }
            .tint(MeshTheme.accentFallback)
            .listRowBackground(MeshTheme.surface)

            // Fix #8: Telemetry pickers
            HStack {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .foregroundStyle(MeshTheme.accentFallback)
                    .frame(width: 24)
                Picker("Telemetry Base", selection: $telBase) {
                    ForEach(telemetryOptions, id: \.0) { val, label in
                        Text(label).tag(val)
                    }
                }
                .foregroundStyle(MeshTheme.textPrimary)
                .tint(MeshTheme.accentFallback)
            }
            .listRowBackground(MeshTheme.surface)

            HStack {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundStyle(MeshTheme.accentFallback)
                    .frame(width: 24)
                Picker("Telemetry Location", selection: $telLoc) {
                    ForEach(telemetryOptions, id: \.0) { val, label in
                        Text(label).tag(val)
                    }
                }
                .foregroundStyle(MeshTheme.textPrimary)
                .tint(MeshTheme.accentFallback)
            }
            .listRowBackground(MeshTheme.surface)

            Toggle(isOn: $advertLoc) {
                HStack {
                    Image(systemName: "location.slash")
                        .foregroundStyle(MeshTheme.accentFallback)
                        .frame(width: 24)
                    Text("Share Location in Advert")
                        .foregroundStyle(MeshTheme.textPrimary)
                }
            }
            .tint(MeshTheme.accentFallback)
            .listRowBackground(MeshTheme.surface)

            Toggle(isOn: $multiACK) {
                HStack {
                    Image(systemName: "checkmark.message")
                        .foregroundStyle(MeshTheme.accentFallback)
                        .frame(width: 24)
                    Text("Multi-ACK")
                        .foregroundStyle(MeshTheme.textPrimary)
                }
            }
            .tint(MeshTheme.accentFallback)
            .listRowBackground(MeshTheme.surface)

            HStack {
                Image(systemName: "lock")
                    .foregroundStyle(MeshTheme.accentFallback)
                    .frame(width: 24)
                Text("BLE PIN")
                    .foregroundStyle(MeshTheme.textPrimary)
                Spacer()
                #if os(watchOS)
                TextField("PIN", text: $pinText)
                    .foregroundStyle(MeshTheme.textPrimary)
                    .frame(width: 80)
                #else
                TextField("PIN", text: $pinText)
                    .foregroundStyle(MeshTheme.textPrimary)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                #endif
                Button {
                    pinText = String(Int.random(in: 100000...999999))
                } label: {
                    Image(systemName: "dice")
                        .foregroundStyle(MeshTheme.accentFallback)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .help("Randomize PIN")
            }
            .listRowBackground(MeshTheme.surface)

            SaveButton(state: saveState, label: "Save Privacy Settings") {
                viewModel.setOtherParams(
                    manualAddContacts: manualAdd ? 1 : 0,
                    telemetryBase: telBase,
                    telemetryLocation: telLoc,
                    advertLocPolicy: advertLoc ? 1 : 0,
                    multiACK: multiACK ? 1 : 0
                )
                if let pin = UInt32(pinText) {
                    viewModel.setDevicePIN(pin)
                }
                showSaved($saveState)
            }
        } header: {
            Text("Privacy & Security")
                .foregroundStyle(MeshTheme.textSecondary)
        } footer: {
            // Fix #12
            Text("Controls what information your device shares with the mesh network.")
                .foregroundStyle(MeshTheme.textSecondary)
                .font(.caption2)
        }
        .onAppear { loadFromConfig() }
        .onChange(of: viewModel.deviceConfig.manualAddContacts) { _ in loadFromConfig() }
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
                    .foregroundStyle(MeshTheme.accentFallback)
                    .frame(width: 24)
                Text("Device Time")
                    .foregroundStyle(MeshTheme.textPrimary)
                Spacer()
                Text(deviceTimeString)
                    .foregroundStyle(MeshTheme.textSecondary)
                    .font(.caption)
            }
            .listRowBackground(MeshTheme.surface)

            Button {
                let epoch = UInt32(Date().timeIntervalSince1970)
                viewModel.setDeviceTime(epochSeconds: epoch)
            } label: {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(MeshTheme.accentFallback)
                        .frame(width: 24)
                    Text("Sync to Phone Time")
                        .foregroundStyle(MeshTheme.accentFallback)
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
            if viewModel.deviceConfig.customVars.isEmpty {
                Text("No custom variables")
                    .foregroundStyle(MeshTheme.textSecondary)
                    .listRowBackground(MeshTheme.surface)
            } else {
                ForEach(Array(viewModel.deviceConfig.customVars.enumerated()), id: \.offset) { _, pair in
                    HStack {
                        Text(pair.name)
                            .foregroundStyle(MeshTheme.textPrimary)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        Text(pair.value)
                            .foregroundStyle(MeshTheme.textSecondary)
                            .font(.system(.body, design: .monospaced))
                    }
                    .listRowBackground(MeshTheme.surface)
                }
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
                    .textFieldStyle(.roundedBorder)
                TextField("Value", text: $newValue)
                    .foregroundStyle(MeshTheme.textPrimary)
                    .textFieldStyle(.roundedBorder)
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
                        .foregroundStyle(MeshTheme.accentFallback)
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
            // Core
            infoRow(icon: "battery.75", label: "Battery (stats)", value: config.statsBatteryMV != 0 ? "\(config.statsBatteryMV) mV" : "\u{2014}")
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
                        .foregroundStyle(MeshTheme.accentFallback)
                        .frame(width: 24)
                    Text("Refresh Stats")
                        .foregroundStyle(MeshTheme.accentFallback)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(MeshTheme.surface)
        } header: {
            sectionHeader("Statistics")
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
                Text("Are you sure? The device will restart and you will need to reconnect.")
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
            // Fix #12
            Text("These actions cannot be undone.")
                .foregroundStyle(MeshTheme.textSecondary)
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
                        .foregroundStyle(MeshTheme.accentFallback)
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
                .foregroundStyle(MeshTheme.accentFallback)
                .frame(width: 24)
            Text(label)
                .foregroundStyle(MeshTheme.textPrimary)
            Spacer()
            Text(value)
                .foregroundStyle(MeshTheme.textSecondary)
        }
        .listRowBackground(MeshTheme.surface)
    }

    func sectionHeader(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(MeshTheme.textSecondary)
    }
}
