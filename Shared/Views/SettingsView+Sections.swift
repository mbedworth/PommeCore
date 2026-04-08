//
//  SettingsView+Sections.swift
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

// MARK: - Notifications

extension SettingsView {
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

extension SettingsView {
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

extension SettingsView {
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
    @Environment(ConnectionManager.self) private var connectionManager
    @Binding var batteryChemistryRaw: String
    @Binding var showSetupWizard: Bool
    var connectedDeviceName: String?
    @State private var firmwareChecker = FirmwareUpdateChecker()
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
            HStack(spacing: 6) {
                Text(config.semanticVersion.isEmpty ? "v\(config.firmwareVersion)" : config.semanticVersion)
                    .foregroundStyle(MeshTheme.textSecondary)
                if !firmwareChecker.isUpdateAvailable && firmwareChecker.latestVersion != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
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
            firmwareUpdateRow
            verifyConfigRow
            verifyConfigResult
            #else
            iOSDeviceRows
            firmwareUpdateRow
            verifyConfigRow
            verifyConfigResult
            #endif
        } header: {
            SectionInfoHeader(title: "Device", info: "Tap any row to view or change that setting on your connected radio.")
        }
        .onAppear { firmwareChecker.checkIfNeeded(currentVersion: config.semanticVersion) }
    }

    private var firmwareUpdateRow: some View {
        Group {
            if firmwareChecker.isUpdateAvailable, let latest = firmwareChecker.latestVersion {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Firmware Update Available")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(MeshTheme.textPrimary)
                        let current = FirmwareUpdateChecker.extractVersion(config.semanticVersion.isEmpty ? config.firmwareVersion : config.semanticVersion)
                        Text("v\(latest) is available (you have v\(current))")
                            .font(.caption)
                            .foregroundStyle(MeshTheme.textSecondary)
                    }
                    Spacer()
                }
                .listRowBackground(MeshTheme.surface)
            } else if firmwareChecker.isChecking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking for updates...")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                }
                .listRowBackground(MeshTheme.surface)
            }
        }
    }

    private var verifyConfigRow: some View {
        Button {
            connectionManager.verifyRadioConfig()
        } label: {
            HStack {
                Label("Verify Radio Config", systemImage: "checkmark.shield")
                    .foregroundStyle(MeshTheme.accent)
                Spacer()
                if connectionManager.isVerifyingConfig {
                    ProgressView()
                        #if !os(watchOS)
                        .controlSize(.small)
                        #endif
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(connectionManager.connectionState != .ready || connectionManager.isVerifyingConfig)
        .listRowBackground(MeshTheme.surface)
    }

    @ViewBuilder
    private var verifyConfigResult: some View {
        if let result = connectionManager.lastConfigVerification {
            VStack(alignment: .leading, spacing: 6) {
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

extension SettingsView {
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

extension SettingsView {
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

extension SettingsView {
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
                SectionInfoHeader(title: "Contacts with Telemetry Permission", info: "Contacts listed here can request battery, temperature, and sensor data from your device. Toggle off to stop sharing telemetry with a specific contact.")
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
                SectionInfoHeader(title: "Contacts with Location Permission", info: "Contacts listed here will receive your GPS coordinates when they request telemetry. Toggle off to stop sharing your location with a specific contact.")
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

extension SettingsView {
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

extension SettingsView {
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

