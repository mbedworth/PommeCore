//
//  RemoteManagementView+ManagementSections.swift
//  PommeCore
//
//  Room, Sensor, Maintenance, Serial-only, CLI Terminal sections and reusable row helpers.
//
//  Created by Michael P. Bedworth on 3/13/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import SwiftUI
import MeshCoreKit

// MARK: - Room Server Section

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
                .tint(.primary)
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

// MARK: - Serial Only Section (macOS)

#if os(macOS) || targetEnvironment(macCatalyst)
struct SerialOnlySection: View {
    let sendCLI: (String) -> Void
    @State private var showFactoryResetConfirm = false
    @State private var showRestoreKeyAlert = false
    @State private var restoreKeyText = ""
    @State private var backupCopied = false

    var body: some View {
        Section {
            CLICommandButton(icon: "doc.text", label: "Dump Log to Terminal") {
                sendCLI("log")
            }

            CLICommandButton(icon: "key.fill", label: "View Private Key", color: .orange) {
                sendCLI("get prv.key")
            }

            Button {
                sendCLI("get prv.key")
                // The key will appear in the CLI output — user can copy from there
                showFeedback($backupCopied)
            } label: {
                HStack {
                    Image(systemName: "square.and.arrow.down")
                        .foregroundStyle(.orange)
                        .frame(width: 24)
                    Text(backupCopied ? "Key Shown in Terminal" : "Backup Identity Key")
                        .foregroundStyle(backupCopied ? .green : MeshTheme.accent)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(MeshTheme.surface)

            Button {
                showRestoreKeyAlert = true
            } label: {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(.orange)
                        .frame(width: 24)
                    Text("Restore Identity Key")
                        .foregroundStyle(.orange)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(MeshTheme.surface)
            .alert("Restore Identity Key", isPresented: $showRestoreKeyAlert) {
                TextField("Hex private key", text: $restoreKeyText)
                Button("Cancel", role: .cancel) { restoreKeyText = "" }
                Button("Restore & Reboot") {
                    let key = restoreKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty else { return }
                    sendCLI("set prv.key \(key)")
                    // Reboot required after setting private key
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        sendCLI("reboot")
                    }
                    restoreKeyText = ""
                }
            } message: {
                Text("Paste the hex-encoded private key from a previous backup. The device will reboot after restoring.")
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

// MARK: - CLI Terminal Section

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
