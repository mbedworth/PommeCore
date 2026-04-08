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
                // Phase 1 loading indicator (only shows during initial fetch)
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
        // Phase 1 fetch is handled by handleLoginSuccess() in RemoteSessionManager
        // No backup trigger needed here — the login code handles it sequentially
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
            #if os(macOS) || targetEnvironment(macCatalyst)
            .frame(minWidth: 360, minHeight: 500)
            #endif
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
                        .foregroundStyle(remoteAccent)
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
                        .foregroundStyle(MeshTheme.accent)
                    if session.fetchedSections.contains(sectionKey) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(MeshTheme.connected)
                    } else if session.hasCachedSettings(for: sectionKey) {
                        Image(systemName: "arrow.triangle.2.circlepath.circle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
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
                    .foregroundStyle(statusColor)
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
                .id(remoteSessionManager.statusUpdateCounter)

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
                        .foregroundStyle(MeshTheme.accent)
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

// MARK: - Config Section Wrappers

private extension RemoteManagementView {
    var radioSection: some View {
        RemoteRadioSection(contact: contact, session: session, sendCLI: sendCLI, canEdit: canEdit)
    }

    var timingSection: some View {
        RemoteTimingSection(contact: contact, session: session, sendCLI: sendCLI, canEdit: canEdit)
    }

    var routingSection: some View {
        RemoteRoutingSection(session: session, sendCLI: sendCLI, canEdit: canEdit)
    }

    var advertisingSection: some View {
        RemoteAdvertSection(contact: contact, session: session, sendCLI: sendCLI, canEdit: canEdit)
    }
}

// MARK: - Device Section Wrappers

private extension RemoteManagementView {
    var securitySection: some View {
        RemoteSecuritySection(contact: contact, session: session, sendCLI: sendCLI, permission: permission)
    }

    var gpsSection: some View {
        RemoteGPSSection(session: session, sendCLI: sendCLI, canEdit: canEdit)
    }
}

// MARK: - Management Section Wrappers

private extension RemoteManagementView {
    var roomSection: some View {
        RemoteRoomSection(session: session, sendCLI: sendCLI, canEdit: canEdit)
    }

    var sensorSection: some View {
        RemoteSensorSection(session: session, sendCLI: sendCLI)
    }

    var maintenanceSection: some View {
        RemoteMaintenanceSection(session: session, sendCLI: sendCLI, permission: permission)
    }

    var cliTerminalSection: some View {
        CLITerminalSection(contact: contact, session: session)
    }

    #if os(macOS) || targetEnvironment(macCatalyst)
    var serialOnlySection: some View {
        SerialOnlySection(sendCLI: sendCLI)
    }
    #endif
}
