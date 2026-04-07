//
//  RemoteManagementView.swift
//  MeshCoreApple
//
//  Remote admin settings for repeaters, rooms, and sensors via CLI over LoRa or USB.
//
//  Created by Michael P. Bedworth on 3/13/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import SwiftUI
import CoreLocation
import MeshCoreKit

/// Management view for repeater and room server contacts.
struct RemoteManagementView: View {
    let contact: Contact
    @Environment(ContactStore.self) private var contactStore
    @Environment(RemoteSessionManager.self) private var remoteSessionManager
    @ObservedObject var session: RemoteDeviceSession
    // Session persists until firmware timeout or reboot — no manual logout
    @State private var isEditingName = false
    @State private var editedName = ""
    @State private var showRebootAfterRename = false
    @State private var showPubkeyCopied = false
    @State private var showNameWizard = false

    // Phase 2 section expand state — collapsed by default, fetch on expand
    @State private var expandedTimingSection = false
    @State private var expandedRoutingSection = false
    @State private var expandedGPSSection = false
    @State private var expandedSecuritySection = false
    @State private var expandedMaintenanceSection = false

    /// Accent color — teal for room servers, amber for repeaters.
    private var remoteAccent: Color {
        contact.type == .room ? MeshTheme.remoteRoom : MeshTheme.remoteRepeater
    }

    var body: some View {
        List {
            if isLoggedIn {
                remoteBanner
                if !isUSBDevice {
                    disconnectSection
                }
                // Phase 1 loading indicator (only shows during initial info/radio/advertising fetch)
                if session.fetchingSection != nil && !session.fetchedSections.contains("advertising") {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                                .tint(remoteAccent)
                            Text("Loading \(session.fetchingSection ?? "settings")...")
                                .foregroundStyle(MeshTheme.textSecondary)
                        }
                        .listRowBackground(MeshTheme.surface)
                    }
                }
                // Permission-level banner for non-admin users
                if !isAdmin && isLoggedIn {
                    HStack(spacing: 8) {
                        Image(systemName: permission == .guest ? "person" : "eye")
                            .foregroundStyle(permissionBadgeColor)
                        Text(permission == .guest ? "Logged in as Guest \u{2014} no access to settings" : "Logged in as \(permission.displayName) \u{2014} read-only access")
                            .font(.caption)
                            .foregroundStyle(MeshTheme.textSecondary)
                    }
                    .listRowBackground(MeshTheme.surface)
                }

                // === Phase 1: Always visible, auto-fetched on login ===
                infoSection
                if canRead {
                    radioSection
                    advertisingSection
                }

                // === Phase 2: Collapsed by default, fetch on expand ===
                if canRead {
                    lazySectionHeader("Timing & Performance", expanded: $expandedTimingSection, sectionKey: "timing")
                    if expandedTimingSection { timingSection }

                    if contact.type == .repeater {
                        lazySectionHeader("Routing", expanded: $expandedRoutingSection, sectionKey: "routing")
                        if expandedRoutingSection { routingSection }
                    }

                    lazySectionHeader("GPS", expanded: $expandedGPSSection, sectionKey: "gps")
                    if expandedGPSSection { gpsSection }

                    if contact.type == .room { roomSection }
                    if contact.type == .sensor && isAdmin { sensorSection }
                }
                if isAdmin {
                    lazySectionHeader("Security", expanded: $expandedSecuritySection, sectionKey: "security")
                    if expandedSecuritySection { securitySection }

                    lazySectionHeader("Maintenance", expanded: $expandedMaintenanceSection, sectionKey: "maintenance")
                    if expandedMaintenanceSection { maintenanceSection }

                    #if os(macOS) || targetEnvironment(macCatalyst)
                    if isUSBDevice { serialOnlySection }
                    #endif
                    cliTerminalSection
                } else if canRead {
                    lazySectionHeader("Maintenance", expanded: $expandedMaintenanceSection, sectionKey: "maintenance")
                    if expandedMaintenanceSection { maintenanceSection }
                }
            } else {
                loginSection
            }
        }
        .meshListStyle()
        .navigationTitle("Remote Management")
        .task {
            // Backup trigger: fetch Phase 1 if login auto-fetch hasn't started yet
            guard isLoggedIn, !session.fetchedSections.contains("info") else { return }
            await remoteSessionManager.fetchSectionAsync("info", for: contact)
            await remoteSessionManager.fetchSectionAsync("radio", for: contact)
            await remoteSessionManager.fetchSectionAsync("advertising", for: contact)
        }
        .onDisappear {
            // Cancel any in-progress settings fetch immediately
            remoteSessionManager.cancelFetch()
            // Session stays alive — firmware has no logout command and handles
            // session timeout automatically. Clearing local state here causes
            // a mismatch that makes buttons unresponsive.
        }
        #if !os(macOS)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    session.fetchedSections.removeAll()
                    expandedTimingSection = false
                    expandedRoutingSection = false
                    expandedGPSSection = false
                    expandedSecuritySection = false
                    expandedMaintenanceSection = false
                    Task {
                        await remoteSessionManager.fetchSectionAsync("info", for: contact)
                        await remoteSessionManager.fetchSectionAsync("radio", for: contact)
                        await remoteSessionManager.fetchSectionAsync("advertising", for: contact)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(MeshTheme.accent)
                }
                .accessibilityLabel("Reload settings")
                .disabled(session.isFetchingSettings)
            }
        }
        #endif
        .sheet(isPresented: $showNameWizard) {
            NavigationStack {
                NodeSetupWizardView(remoteContext: RemoteWizardContext(
                    contact: contact,
                    publicKeyHex: session.settings["public.key"] ?? "",
                    sendCLI: { command in sendCLI(command) },
                    currentName: session.settings["name"],
                    onNameApplied: { newName in session.settings["name"] = newName },
                    currentFrequencyKHz: {
                        // Parse frequency from "radio" setting (e.g. "906.875,62.5,7,5")
                        guard let radio = session.settings["radio"],
                              let freqStr = radio.split(separator: ",").first,
                              let freqMHz = Double(freqStr) else { return nil }
                        return freqMHz * 1000  // MHz → kHz
                    }()
                ))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showNameWizard = false }
                    }
                }
            }
            .meshTheme()
            .frame(minWidth: 360, minHeight: 500)
        }
    }

    @ViewBuilder
    private var remoteBanner: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: contact.type == .room ? "server.rack" : "antenna.radiowaves.left.and.right")
                        .foregroundStyle(remoteAccent)
                    Text(contactStore.displayName(for: contact))
                        .font(.headline)
                        .foregroundStyle(MeshTheme.textPrimary)
                    Spacer()
                    Text(permission.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(permissionBadgeColor)
                        .clipShape(Capsule())
                }
                Text(isUSBDevice
                    ? "Managing via USB Serial \u{2014} direct connection, no latency."
                    : "Managing \(contactStore.displayName(for: contact)) via LoRa \u{2014} commands travel over the mesh and may take a few seconds.")
                    .font(.caption)
                    .foregroundStyle(MeshTheme.textSecondary)
            }
            .padding(.vertical, 4)
            .listRowBackground(remoteAccent.opacity(0.1))
        }
    }

    @ViewBuilder
    private var disconnectSection: some View {
        Section {
            // No manual logout — session ends on firmware timeout, reboot, or BLE disconnect
        }
    }

    private var isLoggedIn: Bool {
        if case .loggedIn = session.loginState { return true }
        return false
    }

    private var permission: RemotePermission {
        if case .loggedIn(let p) = session.loginState { return p }
        return .guest
    }

    private var isAdmin: Bool { permission.isAdmin }
    private var canEdit: Bool { permission.canEdit }
    private var canRead: Bool { permission.canRead }

    private var isUSBDevice: Bool {
        #if os(macOS) || targetEnvironment(macCatalyst)
        contact.publicKey == remoteSessionManager.usbDeviceContact?.publicKey
        #else
        false
        #endif
    }

    /// Header row for a Phase 2 collapsible section.
    private func lazySectionHeader(_ title: String, expanded: Binding<Bool>, sectionKey: String) -> some View {
        Section {
            Button {
                expanded.wrappedValue.toggle()
                if expanded.wrappedValue {
                    remoteSessionManager.fetchSection(sectionKey, for: contact)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                        .frame(width: 16)
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(MeshTheme.textPrimary)
                    if session.fetchedSections.contains(sectionKey) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(MeshTheme.connected)
                    }
                    Spacer()
                    if session.fetchingSection == sectionKey {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }
            }
            .buttonStyle(.plain)
            .listRowBackground(MeshTheme.surface)
        }
    }

    private var permissionBadgeColor: Color {
        switch permission {
        case .guest: return MeshTheme.textSecondary
        case .readOnly: return .yellow
        case .readWrite: return .blue
        case .admin: return MeshTheme.interactiveGreen
        }
    }

    private func sendCLI(_ command: String) {
        #if os(macOS) || targetEnvironment(macCatalyst)
        // For USB CLI devices, log the command being sent for debugging
        if isUSBDevice {
            DebugLogger.shared.log("REMOTE USB: sendCLI(\(command)) via remoteSessionManager", level: .tx)
        }
        #endif
        remoteSessionManager.sendCLICommand(command, to: contact)
    }

    private func getValue(_ key: String) -> String {
        session.settings[key] ?? "\u{2014}"
    }

    private func commitNameEdit() {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isEditingName = false
            editedName = ""
            return
        }
        sendCLI("set name \(trimmed)")
        session.settings["name"] = trimmed
        isEditingName = false
        editedName = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showRebootAfterRename = true
        }
    }
}

// MARK: - Login Section

private extension RemoteManagementView {
    var loginSection: some View {
        LoginSection(contact: contact, session: session)
    }
}

struct LoginSection: View {
    let contact: Contact
    @ObservedObject var session: RemoteDeviceSession
    @Environment(RemoteSessionManager.self) private var remoteSessionManager
    @State private var password = ""

    var body: some View {
        Section {
            HStack {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(statusColor)
                    .shadow(color: statusColor.opacity(0.5), radius: 3)
                Text("Login Status")
                    .foregroundStyle(MeshTheme.accent)
                Spacer()
                Text(statusLabel)
                    .foregroundStyle(MeshTheme.textPrimary)
            }
            .listRowBackground(MeshTheme.surface)

            if !isLoggedIn {
                HStack {
                    Image(systemName: "lock")
                        .foregroundStyle(MeshTheme.accent)
                        .frame(width: 24)
                    #if os(watchOS)
                    SecureField("Password", text: $password)
                        .foregroundStyle(MeshTheme.textPrimary)
                    #else
                    SecureField("Password", text: $password)
                        .foregroundStyle(MeshTheme.textPrimary)
                        .textFieldStyle(MeshTextFieldStyle())
                        .onChange(of: password) { _, new in
                            if new.count > 15 { password = String(new.prefix(15)) }
                        }
                    #endif
                    InfoButton(text: "Passwords are case-sensitive, max 15 characters.")
                }
                .listRowBackground(MeshTheme.surface)

                if contact.type == .sensor {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("Sensors require admin access. Guest login is not supported.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .listRowBackground(MeshTheme.surface)
                }

                if isLoggingIn {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(MeshTheme.accent)
                        Text("Logging in...")
                            .foregroundStyle(MeshTheme.textSecondary)
                        Spacer()
                        Button("Cancel") {
                            remoteSessionManager.cancelLogin(for: contact)
                        }
                        .foregroundStyle(.red)
                    }
                    .listRowBackground(MeshTheme.surface)
                } else {
                    Button {
                        remoteSessionManager.loginToRemoteDevice(contact, password: password)
                    } label: {
                        HStack {
                            Image(systemName: "arrow.right.circle")
                                .foregroundStyle(MeshTheme.accent)
                                .frame(width: 24)
                            Text("Login")
                                .foregroundStyle(MeshTheme.accent)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(password.isEmpty)
                    .listRowBackground(MeshTheme.surface)
                }

                if case .loginFailed(let msg) = session.loginState {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .listRowBackground(MeshTheme.surface)
                }
            }
        } header: {
            Text("Connection")
                .foregroundStyle(MeshTheme.textSecondary)
        }
    }

    private var isLoggedIn: Bool {
        if case .loggedIn = session.loginState { return true }
        return false
    }

    private var isLoggingIn: Bool {
        if case .loggingIn = session.loginState { return true }
        return false
    }

    private var statusColor: Color {
        switch session.loginState {
        case .loggedIn(let permission):
            switch permission {
            case .guest: MeshTheme.textSecondary
            case .readOnly: .yellow
            case .readWrite: .blue
            case .admin: MeshTheme.connected
            }
        case .loggingIn: MeshTheme.connecting
        case .loginFailed: MeshTheme.disconnected
        case .notLoggedIn: MeshTheme.textSecondary
        }
    }

    private var statusLabel: String {
        switch session.loginState {
        case .loggedIn(let permission): permission.displayName
        case .loggingIn: "Logging in..."
        case .loginFailed: "Failed"
        case .notLoggedIn: "Not logged in"
        }
    }
}

// MARK: - Info Section

private extension RemoteManagementView {
    var infoSection: some View {
        Section {
            // Compact device info card
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if isEditingName {
                        TextField("Device name", text: $editedName, onCommit: {
                            commitNameEdit()
                        })
                        .font(.headline)
                        .foregroundStyle(MeshTheme.textPrimary)
                        .textFieldStyle(.plain)
                        Button {
                            commitNameEdit()
                        } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(MeshTheme.accent)
                        }
                        .buttonStyle(.plain)
                        Button {
                            isEditingName = false
                            editedName = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(MeshTheme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        let currentName = getValue("name").isEmpty || getValue("name") == "\u{2014}" ? contact.name : getValue("name")
                        Text(currentName)
                            .font(.headline)
                            .foregroundStyle(MeshTheme.textPrimary)
                        if canEdit {
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(MeshTheme.textSecondary)
                        }
                    }
                    Spacer()
                    Text(session.settings["role"] ?? (contact.type == .repeater ? "Repeater" : contact.type == .room ? "Room" : "Sensor"))
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                    if !isAdmin {
                        Text("\u{2022} \(permission.displayName)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard canEdit, !isEditingName else { return }
                    let currentName = getValue("name").isEmpty || getValue("name") == "\u{2014}" ? contact.name : getValue("name")
                    editedName = currentName
                    isEditingName = true
                }
                .alert("Reboot Required", isPresented: $showRebootAfterRename) {
                    Button("Reboot Now", role: .destructive) {
                        sendCLI("reboot")
                    }
                    Button("Later", role: .cancel) {}
                } message: {
                    Text("The device name has been updated. A reboot is required for the change to take effect.")
                }
                HStack(spacing: 12) {
                    if !getValue("ver").isEmpty {
                        Label(getValue("ver"), systemImage: "cpu")
                    }
                    Label(contact.outPathLen == 0 ? "direct" : "\(contact.outPathLen & 0x3F) hops", systemImage: "arrow.triangle.branch")
                }
                .font(.caption)
                .foregroundStyle(MeshTheme.textSecondary)

                // Battery and uptime from status response (auto-requested on login)
                HStack(spacing: 12) {
                    if let status = remoteSessionManager.statusByContact[contact.publicKeyPrefix] {
                        if status.batteryMV > 0 {
                            let pct = BatteryProfile.lipo.percentage(forMillivolts: Int(status.batteryMV))
                            Label(String(format: "%.2fV (%d%%)", Double(status.batteryMV) / 1000.0, pct),
                                  systemImage: pct > 75 ? "battery.100" : pct > 50 ? "battery.75" : pct > 25 ? "battery.50" : pct > 0 ? "battery.25" : "battery.0")
                            .foregroundStyle(pct > 50 ? .green : pct > 20 ? .yellow : .red)
                        }
                        let u = status.uptime
                        let d = u / 86400, h = (u % 86400) / 3600, m = (u % 3600) / 60
                        let uptimeStr = d > 0 ? "\(d)d \(h)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m"
                        Label(uptimeStr, systemImage: "clock")
                    }
                    Spacer()
                    Button {
                        remoteSessionManager.requestStatus(for: contact)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                            .foregroundStyle(MeshTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh battery and uptime")
                }
                .font(.caption)
                .foregroundStyle(MeshTheme.textSecondary)

                if let radio = session.settings["radio"], !radio.isEmpty {
                    let tx = session.settings["tx"] ?? ""
                    Text("\(radio)\(!tx.isEmpty ? " \u{2022} \(tx)dBm" : "")")
                        .font(.caption2)
                        .foregroundStyle(MeshTheme.textSecondary)
                }

                if let pubkey = session.settings["public.key"], !pubkey.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: showPubkeyCopied ? "checkmark" : "key")
                            .font(.caption2)
                            .foregroundStyle(showPubkeyCopied ? MeshTheme.interactiveGreen : MeshTheme.textSecondary)
                        Text(showPubkeyCopied ? "Copied!" : String(pubkey.prefix(16)) + "...")
                            .font(.caption2)
                            .foregroundStyle(showPubkeyCopied ? MeshTheme.interactiveGreen : MeshTheme.textSecondary)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "doc.on.doc")
                            .font(.caption2)
                            .foregroundStyle(showPubkeyCopied ? MeshTheme.interactiveGreen : MeshTheme.accent)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        copyToClipboard(pubkey)
                        showFeedback($showPubkeyCopied)
                    }
                }
            }
            .listRowBackground(MeshTheme.surface)

            if canEdit {
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
                .onTapGesture { showNameWizard = true }
                .listRowBackground(MeshTheme.surface)
            }

            RemoteClockRow(session: session, sendCLI: sendCLI)

            if DeviceCapabilities.forContactType(contact.type).hasNeighbors {
                CLICommandButton(icon: "person.3", label: "Neighbors") {
                    sendCLI("neighbors")
                }

                if let neighborsText = session.settings["neighbors"], !neighborsText.isEmpty {
                    Text(neighborsText)
                        .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(MeshTheme.textPrimary)
                    .listRowBackground(MeshTheme.surface)
                }
            }

            CLICommandButton(icon: "arrow.clockwise", label: "Refresh Info") {
                sendCLI("ver")
                sendCLI("clock")
                sendCLI("get bootloader.ver")
            }
        } header: {
            SectionInfoHeader(title: "Device Info", info: "Basic device information. Tap Refresh to re-read version and clock from the device.")
        }
    }
}

// MARK: - Radio Section

private extension RemoteManagementView {
    var radioSection: some View {
        RemoteRadioSection(contact: contact, session: session, sendCLI: sendCLI, canEdit: canEdit)
    }
}

struct RemoteRadioSection: View {
    let contact: Contact
    @ObservedObject var session: RemoteDeviceSession
    let sendCLI: (String) -> Void
    let canEdit: Bool

    @State private var radioParams = ""
    @State private var txPower = ""
    @State private var saveState: SaveButtonState = .idle
    @State private var isRebooting = false

    /// Parse "freq_MHz,bw_kHz,sf,cr" from session settings into components for preset detection.
    private var parsedRadio: (freqKHz: Double, bw: Double, sf: UInt8, cr: UInt8) {
        guard let radio = session.settings["radio"] else { return (0, 0, 0, 0) }
        let parts = radio.replacingOccurrences(of: " ", with: "").split(separator: ",")
        guard parts.count >= 4,
              let freqMHz = Double(parts[0]),
              let bw = Double(parts[1]),
              let sf = UInt8(parts[2]),
              let cr = UInt8(parts[3]) else { return (0, 0, 0, 0) }
        return (freqMHz * 1000, bw, sf, cr) // Convert MHz → kHz for preset comparison
    }

    var body: some View {
        if canEdit {
            RadioPresetPicker(
                onApply: { preset in
                    let freqMHz = String(format: "%.6f", preset.frequencyKHz / 1000.0)
                    let bwStr = preset.bandwidth == preset.bandwidth.rounded() ? "\(Int(preset.bandwidth))" : "\(preset.bandwidth)"
                    let params = "\(freqMHz),\(bwStr),\(preset.spreadingFactor),\(preset.codingRate)"
                    radioParams = params
                    sendCLI("set radio \(params)")
                    // Radio params require reboot to take effect — guard against rapid taps
                    guard !isRebooting else { return }
                    isRebooting = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        sendCLI("reboot")
                    }
                },
                currentFreqKHz: parsedRadio.freqKHz,
                currentBW: parsedRadio.bw,
                currentSF: parsedRadio.sf,
                currentCR: parsedRadio.cr
            )
        }

        Section {
            if canEdit {
                cliEditRow(icon: "antenna.radiowaves.left.and.right", label: "Radio (freq,bw,sf,cr)", text: $radioParams, current: session.settings["radio"])
                cliEditRow(icon: "bolt", label: "TX Power", text: $txPower, current: session.settings["tx"])
            } else {
                cliInfoRow(icon: "antenna.radiowaves.left.and.right", label: "Radio", value: session.settings["radio"] ?? "\u{2014}")
                cliInfoRow(icon: "bolt", label: "TX Power", value: session.settings["tx"] ?? "\u{2014}")
            }
            CLIToggleRow(icon: "repeat", label: "Repeat Mode", settingKey: "repeat", onCommand: "set repeat on", offCommand: "set repeat off", session: session, sendCLI: sendCLI, canEdit: canEdit)

            if canEdit {
                SaveButton(state: saveState, label: "Apply Radio Settings") {
                    if !radioParams.isEmpty { sendCLI("set radio \(radioParams)") }
                    if !txPower.isEmpty { sendCLI("set tx \(txPower)") }
                    showSaved($saveState)
                }
            }
        } header: {
            SectionInfoHeader(title: "Radio Configuration", info: "Radio format: freq_MHz,bw_kHz,sf,cr (e.g. 910.525,62.5,7,5)")
        }
    }
}

// MARK: - Timing Section

private extension RemoteManagementView {
    var timingSection: some View {
        RemoteTimingSection(contact: contact, session: session, sendCLI: sendCLI, canEdit: canEdit)
    }
}

struct RemoteTimingSection: View {
    let contact: Contact
    @ObservedObject var session: RemoteDeviceSession
    let sendCLI: (String) -> Void
    let canEdit: Bool

    @State private var airtimeFactor = ""
    @State private var rxDelay = ""
    @State private var txDelay = ""
    @State private var directTxDelay = ""
    @State private var floodMax = ""
    @State private var intThresh = ""
    @State private var agcReset = ""
    @State private var saveState: SaveButtonState = .idle
    @State private var isExpanded = false

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $isExpanded) {
                cliEditRow(icon: "clock.arrow.2.circlepath", label: "Airtime Factor", text: $airtimeFactor, current: session.settings["af"])
                cliEditRow(icon: "timer", label: "RX Delay", text: $rxDelay, current: session.settings["rxdelay"])
                cliEditRow(icon: "arrow.up.circle", label: "TX Delay", text: $txDelay, current: session.settings["txdelay"])
                cliEditRow(icon: "arrow.right.circle", label: "Direct TX Delay", text: $directTxDelay, current: session.settings["direct.txdelay"])
                cliEditRow(icon: "arrow.triangle.branch", label: "Flood Max Hops", text: $floodMax, current: session.settings["flood.max"])
                cliEditRow(icon: "waveform.badge.exclamationmark", label: "Interference Thresh", text: $intThresh, current: session.settings["int.thresh"])
                cliEditRow(icon: "dial.low", label: "AGC Reset Interval", text: $agcReset, current: session.settings["agc.reset.interval"])

                if canEdit {
                    SaveButton(state: saveState, label: "Apply Settings") {
                        if !airtimeFactor.isEmpty { sendCLI("set af \(airtimeFactor)") }
                        if !rxDelay.isEmpty { sendCLI("set rxdelay \(rxDelay)") }
                        if !txDelay.isEmpty { sendCLI("set txdelay \(txDelay)") }
                        if !directTxDelay.isEmpty { sendCLI("set direct.txdelay \(directTxDelay)") }
                        if !floodMax.isEmpty { sendCLI("set flood.max \(floodMax)") }
                        if !intThresh.isEmpty { sendCLI("set int.thresh \(intThresh)") }
                        if !agcReset.isEmpty { sendCLI("set agc.reset.interval \(agcReset)") }
                        showSaved($saveState)
                    }
                }
            } label: {
                Label("Timing & Performance", systemImage: "slider.horizontal.3")
                    .foregroundStyle(MeshTheme.accent)
            }
            .listRowBackground(MeshTheme.surface)
        } header: {
            SectionInfoHeader(title: "", info: "Advanced — adjust timing parameters for mesh performance. Default values work well for most setups. Flood Max Hops supports 0\u{2013}64 (default 64).")
        }
        .disabled(!canEdit)
    }
}

// MARK: - Advertising Section

private extension RemoteManagementView {
    var routingSection: some View {
        RemoteRoutingSection(session: session, sendCLI: sendCLI, canEdit: canEdit)
    }
}

struct RemoteRoutingSection: View {
    @ObservedObject var session: RemoteDeviceSession
    let sendCLI: (String) -> Void
    let canEdit: Bool
    @State private var loopDetect = ""
    @State private var pathHashMode = ""
    @State private var saveState: SaveButtonState = .idle
    @State private var isExpanded = false

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $isExpanded) {
                HStack {
                    Image(systemName: "arrow.triangle.capsulepath")
                        .foregroundStyle(MeshTheme.accent)
                        .frame(width: 24)
                    Picker("Loop Detection", selection: loopDetectBinding) {
                        Text("Off").tag("off")
                        Text("Min").tag("minimal")
                        Text("Mod").tag("moderate")
                        Text("Strict").tag("strict")
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(MeshTheme.surface)

                HStack {
                    Image(systemName: "number.circle")
                        .foregroundStyle(MeshTheme.accent)
                        .frame(width: 24)
                    Picker("Path Hash", selection: pathHashBinding) {
                        Text("1-byte").tag("1")
                        Text("2-byte").tag("2")
                        Text("3-byte").tag("3")
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(MeshTheme.surface)

                CLICommandButton(icon: "antenna.radiowaves.left.and.right", label: "Discover Neighbors") {
                    sendCLI("discover.neighbors")
                }

                if let neighborsResult = session.settings["discover.neighbors"], !neighborsResult.isEmpty {
                    Text(neighborsResult)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(MeshTheme.textPrimary)
                        .listRowBackground(MeshTheme.surface)
                }
            } label: {
                Label("Advanced Routing", systemImage: "arrow.triangle.branch")
                    .foregroundStyle(MeshTheme.accent)
            }
            .listRowBackground(MeshTheme.surface)
        } header: {
            SectionInfoHeader(title: "", info: "Loop detection rejects flood packets that appear to be in a loop (v1.14+). Path hash size controls ID/hash encoding in path headers \u{2014} higher values reduce collision risk but require v1.14+ firmware across the network.")
        }
        .disabled(!canEdit)
    }

    private var loopDetectBinding: Binding<String> {
        Binding(
            get: {
                if !loopDetect.isEmpty { return loopDetect }
                return session.settings["loop.detect"] ?? "off"
            },
            set: { newValue in
                loopDetect = newValue
                sendCLI("set loop.detect \(newValue)")
            }
        )
    }

    private var pathHashBinding: Binding<String> {
        Binding(
            get: {
                if !pathHashMode.isEmpty { return pathHashMode }
                return session.settings["path.hash.mode"] ?? "1"
            },
            set: { newValue in
                pathHashMode = newValue
                sendCLI("set path.hash.mode \(newValue)")
            }
        )
    }
}

private extension RemoteManagementView {
    var advertisingSection: some View {
        RemoteAdvertSection(contact: contact, session: session, sendCLI: sendCLI, canEdit: canEdit)
    }
}

struct RemoteAdvertSection: View {
    let contact: Contact
    @ObservedObject var session: RemoteDeviceSession
    let sendCLI: (String) -> Void
    let canEdit: Bool

    @State private var name = ""
    @State private var lat = ""
    @State private var lon = ""
    @State private var ownerInfo = ""
    @State private var advertInterval = ""
    @State private var floodAdvertInterval = ""
    @State private var saveState: SaveButtonState = .idle
    @State private var showAdvertOptions = false
    @State private var showAdvertSent = false

    var body: some View {
        Section {
            cliEditRow(icon: "person.text.rectangle", label: "Name", text: $name, current: session.settings["name"])
            cliEditRow(icon: "location", label: "Latitude", text: $lat, current: session.settings["lat"])
            cliEditRow(icon: "location", label: "Longitude", text: $lon, current: session.settings["lon"])
            cliEditRow(icon: "person.crop.rectangle", label: "Owner Info", text: $ownerInfo, current: session.settings["owner.info"])
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(MeshTheme.accent)
                    .frame(width: 24)
                Picker("Standard Advert", selection: standardAdvertBinding) {
                    Text("Disabled").tag("0")
                    Text("60 min").tag("60")
                    Text("90 min").tag("90")
                    Text("120 min").tag("120")
                    Text("180 min").tag("180")
                    Text("240 min").tag("240")
                }
                .foregroundStyle(MeshTheme.accent)
                .tint(MeshTheme.accent)
            }
            .listRowBackground(MeshTheme.surface)

            HStack {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(MeshTheme.accent)
                    .frame(width: 24)
                Picker("Flood Advert", selection: floodAdvertBinding) {
                    Text("Disabled").tag("0")
                    Text("3 hours").tag("3")
                    Text("6 hours").tag("6")
                    Text("12 hours").tag("12")
                    Text("24 hours").tag("24")
                }
                .foregroundStyle(MeshTheme.accent)
                .tint(MeshTheme.accent)
            }
            .listRowBackground(MeshTheme.surface)
            CLIToggleRow(icon: "checkmark.message", label: "Multi-ACKs", settingKey: "multi.acks", onCommand: "set multi.acks 1", offCommand: "set multi.acks 0", session: session, sendCLI: sendCLI, canEdit: canEdit)

            if canEdit {
                HStack(spacing: 12) {
                    SaveButton(state: saveState, label: "Save Advertising") {
                        // Send owner.info, lat, lon BEFORE name —
                        // "set name" must be last (firmware may restart advert system)
                        if !ownerInfo.isEmpty { sendCLI("set owner.info \(ownerInfo)") }
                        if !lat.isEmpty { sendCLI("set lat \(lat)") }
                        if !lon.isEmpty { sendCLI("set lon \(lon)") }
                        if !name.isEmpty { sendCLI("set name \(name)") }
                        // Advert intervals handled via picker bindings
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
            }
        } header: {
            SectionInfoHeader(title: "Advertising", info: "Standard adverts are local (0-hop, 60-240 min). Flood adverts are relayed by all repeaters (min 3 hours). Minimum intervals enforced by firmware.")
        }
        .confirmationDialog("Send Advertisement", isPresented: $showAdvertOptions) {
            Button("Zero-Hop (nearby only)") {
                sendCLI("advert.zerohop")
                showFeedback($showAdvertSent)
            }
            Button("Flood (entire mesh)") {
                sendCLI("advert")
                showFeedback($showAdvertSent)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Zero-hop reaches nearby nodes only. Flood is relayed by repeaters across the entire mesh network.")
        }
        .disabled(!canEdit)
    }

    private var standardAdvertBinding: Binding<String> {
        Binding(
            get: {
                if !advertInterval.isEmpty { return advertInterval }
                return session.settings["advert.interval"] ?? "120"
            },
            set: { newValue in
                advertInterval = newValue
                sendCLI("set advert.interval \(newValue)")
            }
        )
    }

    private var floodAdvertBinding: Binding<String> {
        Binding(
            get: {
                if !floodAdvertInterval.isEmpty { return floodAdvertInterval }
                return session.settings["flood.advert.interval"] ?? "3"
            },
            set: { newValue in
                floodAdvertInterval = newValue
                sendCLI("set flood.advert.interval \(newValue)")
            }
        )
    }
}

// MARK: - Security Section

private extension RemoteManagementView {
    var securitySection: some View {
        RemoteSecuritySection(contact: contact, session: session, sendCLI: sendCLI, permission: permission)
    }
}

struct RemoteSecuritySection: View {
    let contact: Contact
    @ObservedObject var session: RemoteDeviceSession
    let sendCLI: (String) -> Void
    let permission: RemotePermission

    @State private var adminPassword = ""
    @State private var guestPassword = ""

    var body: some View {
        Section {
            if permission.isAdmin {
                HStack {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(MeshTheme.accent)
                        .frame(width: 24)
                    #if os(watchOS)
                    SecureField("New Admin Password", text: $adminPassword)
                        .foregroundStyle(MeshTheme.textPrimary)
                    #else
                    SecureField("New Admin Password", text: $adminPassword)
                        .foregroundStyle(MeshTheme.textPrimary)
                        .textFieldStyle(MeshTextFieldStyle())
                        .onChange(of: adminPassword) { _, new in
                            if new.count > 15 { adminPassword = String(new.prefix(15)) }
                        }
                    #endif
                    Button {
                        guard !adminPassword.isEmpty else { return }
                        sendCLI("password \(adminPassword)")
                        adminPassword = ""
                    } label: {
                        Text("Set")
                            .foregroundStyle(MeshTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
                .listRowBackground(MeshTheme.surface)
            }

            HStack {
                Image(systemName: "lock")
                    .foregroundStyle(MeshTheme.accent)
                    .frame(width: 24)
                #if os(watchOS)
                SecureField("Guest Password", text: $guestPassword)
                    .foregroundStyle(MeshTheme.textPrimary)
                #else
                SecureField("Guest Password", text: $guestPassword)
                    .foregroundStyle(MeshTheme.textPrimary)
                    .textFieldStyle(MeshTextFieldStyle())
                    .onChange(of: guestPassword) { _, new in
                        if new.count > 15 { guestPassword = String(new.prefix(15)) }
                    }
                #endif
                Button {
                    guard !guestPassword.isEmpty else { return }
                    sendCLI("set guest.password \(guestPassword)")
                    guestPassword = ""
                } label: {
                    Text("Set")
                        .foregroundStyle(MeshTheme.accent)
                }
                .buttonStyle(.plain)
            }
            .listRowBackground(MeshTheme.surface)

            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundStyle(MeshTheme.textSecondary)
                    .frame(width: 24)
                Text("ACL requires USB serial connection")
                    .font(.caption)
                    .foregroundStyle(MeshTheme.textSecondary)
            }
            .listRowBackground(MeshTheme.surface)
        } header: {
            SectionInfoHeader(title: "Security", info: "ACL permissions: 0=Guest, 1=Read-only, 2=Read-write, 3=Admin")
        }
    }
}

// MARK: - GPS Section

private extension RemoteManagementView {
    var gpsSection: some View {
        RemoteGPSSection(session: session, sendCLI: sendCLI, canEdit: canEdit)
    }
}

struct RemoteGPSSection: View {
    @ObservedObject var session: RemoteDeviceSession
    let sendCLI: (String) -> Void
    let canEdit: Bool
    @State private var gpsSyncFeedback = false
    @State private var gpsLocFeedback = false
    @State private var mapPickFeedback = false
    @State private var gpsAdvertMode = ""
    @State private var showMapPicker = false
    @State private var mapPickedCoordinate: CLLocationCoordinate2D?

    var body: some View {
        Section {
            CLIToggleRow(icon: "location.circle", label: "GPS", settingKey: "gps", onCommand: "gps on", offCommand: "gps off", session: session, sendCLI: sendCLI, canEdit: canEdit)

            if canEdit {
            HStack(spacing: 12) {
                Button {
                    sendCLI("gps sync")
                    showFeedback($gpsSyncFeedback)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { sendCLI("clock") }
                } label: {
                    Label(gpsSyncFeedback ? "Clock Synced" : "Sync Time", systemImage: gpsSyncFeedback ? "checkmark.circle.fill" : "clock.arrow.2.circlepath")
                        .foregroundStyle(gpsSyncFeedback ? .green : MeshTheme.accent)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    sendCLI("gps setloc")
                    showFeedback($gpsLocFeedback)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        sendCLI("get lat")
                        sendCLI("get lon")
                    }
                } label: {
                    Label(gpsLocFeedback ? "Location Set" : "Set Location", systemImage: gpsLocFeedback ? "checkmark.circle.fill" : "mappin")
                        .foregroundStyle(gpsLocFeedback ? .green : MeshTheme.accent)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    // Pre-populate with remote device's current lat/lon if available
                    if let latStr = session.settings["lat"], let lonStr = session.settings["lon"],
                       let lat = Double(latStr), let lon = Double(lonStr), lat != 0 || lon != 0 {
                        mapPickedCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    }
                    showMapPicker = true
                } label: {
                    Label(mapPickFeedback ? "Location Set" : "Pick on Map", systemImage: mapPickFeedback ? "checkmark.circle.fill" : "map")
                        .foregroundStyle(mapPickFeedback ? .green : MeshTheme.accent)
                }
                .buttonStyle(.plain)

            }
            .listRowBackground(MeshTheme.surface)

            HStack {
                Image(systemName: "location.north.line")
                    .foregroundStyle(MeshTheme.accent)
                    .frame(width: 24)
                Picker("Location in Advertisements", selection: gpsAdvertBinding) {
                    Text("None \u{2014} don't include location").tag("none")
                    Text("GPS \u{2014} use live GPS coordinates").tag("share")
                    Text("Manual \u{2014} use saved lat/lon settings").tag("prefs")
                }
                .foregroundStyle(MeshTheme.accent)
                .tint(MeshTheme.accent)
            }
            .listRowBackground(MeshTheme.surface)
            }
        } header: {
            SectionInfoHeader(title: "GPS", info: "Controls whether this device includes its location in mesh advertisements. \u{2018}GPS\u{2019} uses the hardware GPS module. \u{2018}Manual\u{2019} uses the latitude and longitude values configured in the advertising section.")
        }
        .sheet(isPresented: $showMapPicker, onDismiss: {
            guard let coord = mapPickedCoordinate else { return }
            sendCLI("set lat \(String(format: "%.6f", coord.latitude))")
            sendCLI("set lon \(String(format: "%.6f", coord.longitude))")
            showFeedback($mapPickFeedback)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                sendCLI("get lat")
                sendCLI("get lon")
            }
        }) {
            MapPointPickerView(selectedCoordinate: $mapPickedCoordinate)
                .frame(minWidth: 500, idealWidth: 700, minHeight: 500, idealHeight: 600)
        }
    }

    private var gpsAdvertBinding: Binding<String> {
        Binding(
            get: {
                if !gpsAdvertMode.isEmpty { return gpsAdvertMode }
                return session.settings["gps advert"] ?? session.settings["gps.advert"] ?? "none"
            },
            set: { newValue in
                gpsAdvertMode = newValue
                sendCLI("gps advert \(newValue)")
            }
        )
    }
}

// MARK: - Room Server Section

private extension RemoteManagementView {
    var roomSection: some View {
        RemoteRoomSection(session: session, sendCLI: sendCLI, canEdit: canEdit)
    }

    var sensorSection: some View {
        RemoteSensorSection(session: session, sendCLI: sendCLI)
    }
}

struct RemoteRoomSection: View {
    @ObservedObject var session: RemoteDeviceSession
    let sendCLI: (String) -> Void
    let canEdit: Bool

    @State private var setPermPubkey = ""
    @State private var setPermLevel = 0
    @State private var permFeedback = false

    var body: some View {
        Section {
            CLIToggleRow(icon: "eye", label: "Allow Read-Only", settingKey: "allow.read.only", onCommand: "set allow.read.only on", offCommand: "set allow.read.only off", session: session, sendCLI: sendCLI, canEdit: canEdit)

            if let guestPw = session.settings["guest.password"], !guestPw.isEmpty {
                cliInfoRow(icon: "key", label: "Guest Password", value: guestPw)
            }
        } header: {
            SectionInfoHeader(title: "Room Server", info: "Allow Read-Only lets guests read messages without a password. Disable to require authentication for all access.")
        }

        if canEdit {
            Section {
                HStack {
                    Image(systemName: "person.badge.key")
                        .foregroundStyle(MeshTheme.accent)
                        .frame(width: 24)
                    #if os(watchOS)
                    TextField("Pubkey hex", text: $setPermPubkey)
                        .foregroundStyle(MeshTheme.textPrimary)
                    #else
                    TextField("Pubkey hex prefix", text: $setPermPubkey)
                        .foregroundStyle(MeshTheme.textPrimary)
                        .textFieldStyle(MeshTextFieldStyle())
                        .font(.system(.body, design: .monospaced))
                    #endif
                }
                .listRowBackground(MeshTheme.surface)

                Picker("Permission Level", selection: $setPermLevel) {
                    Text("Guest (read-only)").tag(0)
                    Text("Read-Write").tag(2)
                    Text("Admin").tag(3)
                }
                .foregroundStyle(MeshTheme.accent)
                .tint(MeshTheme.accent)
                .listRowBackground(MeshTheme.surface)

                Button {
                    sendCLI("setperm \(setPermPubkey) \(setPermLevel)")
                    showFeedback($permFeedback)
                    setPermPubkey = ""
                } label: {
                    HStack {
                        Image(systemName: permFeedback ? "checkmark.circle.fill" : "lock.rotation")
                            .foregroundStyle(permFeedback ? .green : MeshTheme.accent)
                            .frame(width: 24)
                        Text(permFeedback ? "Permission Set" : "Set Permission")
                            .foregroundStyle(permFeedback ? .green : MeshTheme.accent)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(setPermPubkey.isEmpty)
                .listRowBackground(MeshTheme.surface)
            } header: {
                SectionInfoHeader(title: "Client Permissions", info: "Set access level for a client by their public key prefix. Guest = read-only, Read-Write = can post, Admin = full control.")
            }
        }
    }
}

// MARK: - Sensor Section

struct RemoteSensorSection: View {
    @ObservedObject var session: RemoteDeviceSession
    let sendCLI: (String) -> Void
    @State private var gpioPin = ""

    var body: some View {
        Section {
            CLICommandButton(icon: "cpu", label: "Read All GPIO Pins") {
                sendCLI("io")
            }

            if let ioResult = session.settings["io"], !ioResult.isEmpty {
                Text(ioResult)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(MeshTheme.textPrimary)
                    .listRowBackground(MeshTheme.surface)
            }

            HStack(spacing: 8) {
                Image(systemName: "pin")
                    .foregroundStyle(MeshTheme.accent)
                    .frame(width: 24)
                #if os(watchOS)
                TextField("Pin", text: $gpioPin)
                    .frame(width: 40)
                #else
                TextField("Pin", text: $gpioPin)
                    .frame(width: 40)
                    .textFieldStyle(MeshTextFieldStyle())
                #endif
                Button("Set") { sendCLI("io s\(gpioPin)") }
                    .foregroundStyle(MeshTheme.accent)
                    .buttonStyle(.plain)
                Button("Reset") { sendCLI("io r\(gpioPin)") }
                    .foregroundStyle(.orange)
                    .buttonStyle(.plain)
                Button("Toggle") { sendCLI("io t\(gpioPin)") }
                    .foregroundStyle(MeshTheme.accent)
                    .buttonStyle(.plain)
            }
            .listRowBackground(MeshTheme.surface)
            .disabled(gpioPin.isEmpty)
        } header: {
            SectionInfoHeader(title: "Sensor GPIO", info: "Direct GPIO pin control. Use with caution \u{2014} incorrect operations may affect sensor readings.")
        }
    }
}

// MARK: - Maintenance Section

private extension RemoteManagementView {
    var maintenanceSection: some View {
        RemoteMaintenanceSection(session: session, sendCLI: sendCLI, permission: permission)
    }
}

struct RemoteMaintenanceSection: View {
    @ObservedObject var session: RemoteDeviceSession
    let sendCLI: (String) -> Void
    let permission: RemotePermission

    @State private var showRebootConfirm = false
    @State private var adcMultiplier = ""

    var body: some View {
        Section {
            CLIToggleRow(icon: "leaf", label: "Power Saving", settingKey: "powersaving", onCommand: "powersaving on", offCommand: "powersaving off", session: session, sendCLI: sendCLI, canEdit: permission.canEdit)

            if permission.canEdit {
                cliEditRow(icon: "bolt.batteryblock", label: "ADC Multiplier", text: $adcMultiplier, current: session.settings["adc.multiplier"])

                if !adcMultiplier.isEmpty {
                    CLICommandButton(icon: "checkmark.circle", label: "Apply ADC Multiplier") {
                        sendCLI("set adc.multiplier \(adcMultiplier)")
                        adcMultiplier = ""
                    }
                }
            }

            if permission.isAdmin {
                // Region management
                CLICommandButton(icon: "map", label: "List Regions") {
                    sendCLI("region")
                }

                // Logging (start/stop work over BLE; log dump is serial-only)
                HStack(spacing: 12) {
                    Button { sendCLI("log start") } label: {
                        Text("Start Log").foregroundStyle(MeshTheme.accent)
                    }
                    .buttonStyle(.plain)

                    Button { sendCLI("log stop") } label: {
                        Text("Stop Log").foregroundStyle(MeshTheme.textSecondary)
                    }
                    .buttonStyle(.plain)

                }
                .listRowBackground(MeshTheme.surface)

                CLICommandButton(icon: "chart.bar.xaxis", label: "Clear Stats", color: .orange) {
                    sendCLI("clear stats")
                }
            }

            if permission.isAdmin {
                Button {
                    showRebootConfirm = true
                } label: {
                    HStack {
                        Image(systemName: "arrow.counterclockwise.circle")
                            .foregroundStyle(.red)
                            .frame(width: 24)
                        Text("Reboot Device")
                            .foregroundStyle(.red)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(MeshTheme.surface)
                .alert("Reboot Remote Device?", isPresented: $showRebootConfirm) {
                    Button("Cancel", role: .cancel) {}
                    Button("Reboot", role: .destructive) {
                        sendCLI("reboot")
                    }
                } message: {
                    Text("The remote device will restart. You will need to log in again.")
                }
            }
        } header: {
            SectionInfoHeader(title: "Maintenance", info: "Reboot restarts the device (~30 seconds). Clear Stats resets packet counters and airtime. Log dump requires USB serial connection.")
        }
    }
}

// MARK: - CLI Terminal Section

private extension RemoteManagementView {
    var cliTerminalSection: some View {
        CLITerminalSection(contact: contact, session: session)
    }

    #if os(macOS) || targetEnvironment(macCatalyst)
    var serialOnlySection: some View {
        SerialOnlySection(sendCLI: sendCLI)
    }
    #endif
}

#if os(macOS) || targetEnvironment(macCatalyst)
struct SerialOnlySection: View {
    let sendCLI: (String) -> Void
    @State private var showFactoryResetConfirm = false

    var body: some View {
        Section {
            CLICommandButton(icon: "doc.text", label: "Dump Log to Terminal") {
                sendCLI("log")
            }

            CLICommandButton(icon: "key.fill", label: "View Private Key", color: .orange) {
                sendCLI("get prv.key")
            }

            Button {
                showFactoryResetConfirm = true
            } label: {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
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
            .confirmationDialog("Factory Reset?", isPresented: $showFactoryResetConfirm, titleVisibility: .visible) {
                Button("Erase All Data", role: .destructive) {
                    sendCLI("erase")
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Permanently erases ALL data including keys, contacts, and settings. This cannot be undone.")
            }
        } header: {
            SectionInfoHeader(title: "USB Serial Commands", info: "These commands are only available via direct USB connection for security. Factory Reset cannot be undone.")
        }
    }
}
#endif

struct CLITerminalSection: View {
    let contact: Contact
    @ObservedObject var session: RemoteDeviceSession
    @Environment(RemoteSessionManager.self) private var remoteSessionManager
    @State private var commandText = ""
    @FocusState private var isCommandFieldFocused: Bool

    var body: some View {
        Section {
            DisclosureGroup("CLI Terminal") {
            // History
            if !session.cliHistory.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(session.cliHistory) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("> \(entry.command)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(MeshTheme.accent)
                                if let response = entry.response {
                                    Text(response)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(MeshTheme.textPrimary)
                                } else {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                        .tint(MeshTheme.textSecondary)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 200)
                .listRowBackground(MeshTheme.background)
            }

            // Input
            HStack(spacing: 8) {
                Text(">")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(MeshTheme.accent)
                #if os(watchOS)
                TextField("CLI command", text: $commandText)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(MeshTheme.textPrimary)
                #else
                TextField("CLI command", text: $commandText)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(MeshTheme.textPrimary)
                    .textFieldStyle(MeshTextFieldStyle())
                    .focused($isCommandFieldFocused)
                    .onSubmit { sendCommand() }
                #endif
                Button(action: sendCommand) {
                    Image(systemName: "return")
                        .foregroundStyle(
                            commandText.isEmpty ? MeshTheme.textSecondary : MeshTheme.accent
                        )
                }
                .buttonStyle(.plain)
                .disabled(commandText.isEmpty)
            }
            .listRowBackground(MeshTheme.surface)
            }
            .listRowBackground(MeshTheme.surface)
        } header: {
            SectionInfoHeader(title: "", info: "Send raw CLI commands to the device. Type 'help' for available commands.")
        }
    }

    private func sendCommand() {
        remoteSessionManager.sendCLICommand(commandText, to: contact)
        commandText = ""
        isCommandFieldFocused = true
    }
}

// MARK: - Remote Clock Row

struct RemoteClockRow: View {
    @ObservedObject var session: RemoteDeviceSession
    let sendCLI: (String) -> Void

    private var clockValue: String {
        guard let raw = session.settings["clock"], !raw.isEmpty else { return "\u{2014}" }
        // If the response looks like a raw epoch number, format it as a date
        if let epoch = Double(raw.trimmingCharacters(in: .whitespaces)), epoch > 1_000_000_000 {
            let date = Date(timeIntervalSince1970: epoch)
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .medium
            return formatter.string(from: date)
        }
        return raw
    }

    /// Check if the clock text indicates a stale date (more than 60 seconds from now).
    private var isClockStale: Bool {
        guard let clockStr = session.settings["clock"], !clockStr.isEmpty else { return false }
        // Try to extract epoch from the response — firmware returns "HH:MM - DD/MM/YYYY" or epoch
        // Check for year mismatch (robust heuristic for date-formatted responses)
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())
        let yearPattern = try? NSRegularExpression(pattern: "\\b(20\\d{2})\\b")
        if let match = yearPattern?.firstMatch(in: clockStr, range: NSRange(clockStr.startIndex..., in: clockStr)),
           let range = Range(match.range(at: 1), in: clockStr),
           let year = Int(clockStr[range]) {
            return abs(year - currentYear) >= 1
        }
        // If response is just an epoch number, compare with 60-second tolerance
        if let epoch = Double(clockStr.trimmingCharacters(in: .whitespaces)) {
            return abs(epoch - Date().timeIntervalSince1970) > 60
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                sendCLI("clock")
            } label: {
                HStack {
                    Image(systemName: "clock")
                        .foregroundStyle(MeshTheme.accent)
                        .frame(width: 24)
                    Text("Clock")
                        .foregroundStyle(MeshTheme.accent)
                    Spacer()
                    Text(clockValue)
                        .foregroundStyle(MeshTheme.textPrimary)
                        .font(.caption)
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                        .foregroundStyle(MeshTheme.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                if isClockStale {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("Clock out of sync")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button {
                    let epoch = Int(Date().timeIntervalSince1970)
                    sendCLI("time \(epoch)")
                    // Refresh clock after a delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        sendCLI("clock")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.2.circlepath")
                            .font(.caption)
                        Text("Sync Clock")
                            .font(.caption)
                    }
                    .foregroundStyle(MeshTheme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .listRowBackground(MeshTheme.surface)
    }
}

// MARK: - Reusable Row Helpers

func cliInfoRow(icon: String, label: String, value: String) -> some View {
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

/// Reusable button row for CLI command actions in remote management.
struct CLICommandButton: View {
    let icon: String
    let label: String
    var color: Color = MeshTheme.accent
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 24)
                Text(label)
                    .foregroundStyle(color)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(MeshTheme.surface)
    }
}

/// A segmented On/Off toggle for CLI boolean settings.
/// Derives its state from the session settings dictionary and sends CLI commands on tap.
struct CLIToggleRow: View {
    let icon: String
    let label: String
    let settingKey: String
    let onCommand: String
    let offCommand: String
    @ObservedObject var session: RemoteDeviceSession
    let sendCLI: (String) -> Void
    var canEdit: Bool = true

    private var isOn: Bool? {
        guard let value = session.settings[settingKey]?.lowercased() else { return nil }
        if value == "on" || value == "1" || value == "true" || value == "enabled" || value.contains("on") { return true }
        if value == "off" || value == "0" || value == "false" || value == "disabled" || value.contains("off") { return false }
        return nil
    }

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(MeshTheme.accent)
                .frame(width: 24)
            Text(label)
                .foregroundStyle(MeshTheme.accent)
            Spacer()
            if canEdit {
                let toggleActive = MeshTheme.interactiveGreen
                HStack(spacing: 0) {
                    Button {
                        sendCLI(onCommand)
                    } label: {
                        Text("On")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(isOn == true ? .black : MeshTheme.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(isOn == true ? toggleActive : Color.clear)
                    }
                    .buttonStyle(.plain)

                    Button {
                        sendCLI(offCommand)
                    } label: {
                        Text("Off")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(isOn == false ? .black : MeshTheme.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(isOn == false ? toggleActive : Color.clear)
                    }
                    .buttonStyle(.plain)
                }
                .background(MeshTheme.background)
                .clipShape(Capsule())
            } else {
                Text(isOn == true ? "On" : isOn == false ? "Off" : "\u{2014}")
                    .foregroundStyle(MeshTheme.textPrimary)
            }
        }
        .listRowBackground(MeshTheme.surface)
    }
}

func cliEditRow(icon: String, label: String, text: Binding<String>, current: String?) -> some View {
    HStack {
        Image(systemName: icon)
            .foregroundStyle(MeshTheme.accent)
            .frame(width: 24)
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(MeshTheme.accent)
            #if os(watchOS)
            TextField(
                "Enter value",
                text: text,
                prompt: Text(current ?? "value").foregroundColor(.primary)
            )
            .foregroundStyle(MeshTheme.textPrimary)
            #else
            TextField(
                "Enter value",
                text: text,
                prompt: Text(current ?? "value").foregroundColor(.primary)
            )
            .foregroundStyle(MeshTheme.textPrimary)
            .textFieldStyle(MeshTextFieldStyle())
            #endif
        }
    }
    .listRowBackground(MeshTheme.surface)
}

