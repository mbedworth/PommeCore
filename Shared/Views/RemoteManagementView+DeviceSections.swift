//
//  RemoteManagementView+DeviceSections.swift
//  PommeCore
//
//  Security, GPS, and Clock sections for remote management.
//
//  Created by Michael P. Bedworth on 3/13/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import SwiftUI
import MeshCoreKit

// MARK: - Security Section

struct RemoteSecuritySection: View {
    let contact: Contact
    @ObservedObject var session: RemoteDeviceSession
    let sendCLI: (String) -> Void
    let permission: RemotePermission

    @State private var adminPassword = ""
    @State private var guestPassword = ""

    var body: some View {
        Group {
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
        }
    }
}

// MARK: - GPS Section

struct RemoteGPSSection: View {
    @ObservedObject var session: RemoteDeviceSession
    let sendCLI: (String) -> Void
    let canEdit: Bool
    @State private var gpsSyncFeedback = false
    @State private var gpsLocFeedback = false
    @State private var gpsAdvertMode = ""

    var body: some View {
        Group {
            CLIToggleRow(icon: "location.circle", label: "GPS", settingKey: "gps", onCommand: "gps on", offCommand: "gps off", session: session, sendCLI: sendCLI, canEdit: canEdit)

            if canEdit {
                HStack(spacing: 12) {
                    Button {
                        let epoch = Int(Date().timeIntervalSince1970)
                        sendCLI("time \(epoch)")
                        sendCLI("gps sync")
                        showFeedback($gpsSyncFeedback)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { sendCLI("clock") }
                    } label: {
                        (gpsSyncFeedback ? Label("Clock Synced", systemImage: "checkmark.circle.fill") : Label("Sync Time", systemImage: "clock.arrow.2.circlepath"))
                            .foregroundStyle(gpsSyncFeedback ? MeshTheme.statusGood : MeshTheme.accent)
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
                        (gpsLocFeedback ? Label("Location Set", systemImage: "checkmark.circle.fill") : Label("Set from Hardware GPS", systemImage: "antenna.radiowaves.left.and.right"))
                            .foregroundStyle(gpsLocFeedback ? MeshTheme.statusGood : MeshTheme.accent)
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
                    .tint(MeshTheme.textPrimary)
                }
                .listRowBackground(MeshTheme.surface)
            }
        }
    }

    private var gpsAdvertBinding: Binding<String> {
        Binding(
            get: {
                if !gpsAdvertMode.isEmpty { return gpsAdvertMode }
                return session.supportedValue(forAny: ["gps advert", "gps.advert"]) ?? "none"
            },
            set: { newValue in
                gpsAdvertMode = newValue
                sendCLI("gps advert \(newValue)")
            }
        )
    }
}

// MARK: - Remote Clock Row

struct RemoteClockRow: View {
    @ObservedObject var session: RemoteDeviceSession
    let sendCLI: (String) -> Void

    /// Both of these read `session.settings["clock"]` directly, so a device with
    /// no `clock` command displayed the literal text "Unknown command" as its
    /// clock — every companion radio, whose time is set over the binary link
    /// with `CMD_SET_DEVICE_TIME` rather than the CLI. Seen on an iPhone
    /// 2026-10-30.
    ///
    /// The logic now lives on `RemoteDeviceSession`, where it is unit-tested and
    /// takes `now` as a parameter. It was unreachable from any test while it sat
    /// in a view, which is the reason it shipped wrong.
    private var clockValue: String { session.clockDisplay() }

    /// Whether the clock looks more than a minute out. An unsupported clock is
    /// not stale: offering to fix a clock the device does not expose is a prompt
    /// the user can never satisfy.
    private var isClockStale: Bool { session.isClockStale() }

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
                        .foregroundStyle(MeshTheme.statusWarn)
                        .font(.caption)
                    Text("Clock out of sync")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.statusWarn)
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
