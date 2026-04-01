//
//  NetworkToolsView.swift
//  MeshCoreApple
//
//  Discover neighbors, trace route, status request, telemetry, and timed discovery.
//
//  Created by Michael P. Bedworth on 3/14/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import SwiftUI
import CryptoKit
import MeshCoreKit

// MARK: - Discover View

struct DiscoverView: View {
    @Environment(ConnectionManager.self) private var connectionManager
    @Environment(RemoteSessionManager.self) private var remoteSessionManager
    @State private var discoveryDuration: TimeInterval = 300
    @State private var timeRemaining: TimeInterval = 0
    @State private var discoveryTimer: Timer?
    @State private var advertTimer: Timer?
    @State private var isTimedDiscovery = false

    var body: some View {
        List {
            Section {
                Button {
                    remoteSessionManager.startDiscover()
                } label: {
                    HStack {
                        Image(systemName: "magnifyingglass.circle")
                            .foregroundStyle(MeshTheme.accent)
                            .frame(width: 24)
                        Text(remoteSessionManager.isDiscovering ? "Restart Scan" : "Start Discover")
                            .foregroundStyle(MeshTheme.accent)
                        Spacer()
                        if remoteSessionManager.isDiscovering {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(MeshTheme.surface)

                if remoteSessionManager.isDiscovering || isTimedDiscovery {
                    Button {
                        remoteSessionManager.stopDiscover()
                        stopTimedDiscovery()
                    } label: {
                        HStack {
                            Image(systemName: "stop.circle")
                                .foregroundStyle(.orange)
                                .frame(width: 24)
                            Text("Stop Scan")
                                .foregroundStyle(.orange)
                            Spacer()
                            if isTimedDiscovery && timeRemaining > 0 {
                                Text(formatTimeRemaining(timeRemaining))
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .monospacedDigit()
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(MeshTheme.surface)
                }

                if remoteSessionManager.isDiscovering {
                    ActivityOverlay(message: "Scanning for nearby nodes...", timeout: 30)
                        .listRowBackground(MeshTheme.surface)
                }

                if let fallbackMsg = remoteSessionManager.discoverFallbackMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.orange)
                        Text(fallbackMsg)
                            .font(.caption)
                            .foregroundStyle(MeshTheme.textSecondary)
                    }
                    .listRowBackground(MeshTheme.surface)
                }
            }

            Section {
                HStack {
                    Image(systemName: "timer")
                        .foregroundStyle(MeshTheme.accent)
                        .frame(width: 24)
                    Picker("Duration", selection: $discoveryDuration) {
                        Text("5 minutes").tag(TimeInterval(300))
                        Text("10 minutes").tag(TimeInterval(600))
                        Text("15 minutes").tag(TimeInterval(900))
                        Text("30 minutes").tag(TimeInterval(1800))
                    }
                    .foregroundStyle(MeshTheme.accent)
                    .tint(MeshTheme.accent)
                }
                .listRowBackground(MeshTheme.surface)

                Button {
                    if isTimedDiscovery { stopTimedDiscovery() }
                    startTimedDiscovery()
                } label: {
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(MeshTheme.accent)
                            .frame(width: 24)
                        Text(isTimedDiscovery ? "Restart Timed Discovery" : "Start Timed Discovery")
                            .foregroundStyle(MeshTheme.accent)
                        Spacer()
                        if isTimedDiscovery {
                            Text(formatTimeRemaining(timeRemaining))
                                .font(.caption)
                                .foregroundStyle(MeshTheme.accent)
                                .monospacedDigit()
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(MeshTheme.surface)
            } header: {
                Text("Timed Discovery")
                    .foregroundStyle(MeshTheme.textSecondary)
            } footer: {
                Text("Sends periodic flood advertisements for the selected duration. Uses more battery and airtime than a single scan.")
                    .font(.caption2)
            }

            if remoteSessionManager.discoveredNodes.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "sensor.tag.radiowaves.forward")
                                .font(.system(size: 36))
                                .foregroundStyle(MeshTheme.textSecondary)
                            Text("No nodes discovered")
                                .font(.subheadline)
                                .foregroundStyle(MeshTheme.textSecondary)
                            Text("Tap Start Discover to scan the mesh")
                                .font(.caption)
                                .foregroundStyle(MeshTheme.textSecondary)
                        }
                        Spacer()
                    }
                    .listRowBackground(MeshTheme.surface)
                }
            } else {
                Section {
                    ForEach(remoteSessionManager.discoveredNodes) { node in
                        discoveredNodeRow(node)
                    }
                } header: {
                    Text("\(remoteSessionManager.discoveredNodes.count) Node\(remoteSessionManager.discoveredNodes.count == 1 ? "" : "s") Found")
                        .foregroundStyle(MeshTheme.textSecondary)
                }
            }
        }
        .meshListStyle()
        .navigationTitle("Discover")
    }

    private func discoveredNodeRow(_ node: DiscoveredNode) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(MeshTheme.accent.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: iconName(for: node.type))
                    .foregroundStyle(MeshTheme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name.isEmpty ? "Unknown" : node.name)
                    .font(.body)
                    .foregroundStyle(MeshTheme.textPrimary)
                HStack(spacing: 8) {
                    Text(typeName(for: node.type))
                        .font(.caption2)
                        .foregroundStyle(MeshTheme.textSecondary)
                    if node.pathLen == 0 {
                        Text("direct")
                            .font(.caption2)
                            .foregroundStyle(MeshTheme.connected)
                    } else {
                        Text("\(node.pathLen) hop\(node.pathLen == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(MeshTheme.textSecondary)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("SNR \(node.snr)")
                    .font(.caption2)
                    .foregroundStyle(snrColor(node.snr))
                Text("RSSI \(node.rssi)")
                    .font(.caption2)
                    .foregroundStyle(MeshTheme.textSecondary)
            }
        }
        .listRowBackground(MeshTheme.surface)
    }

    private func iconName(for type: ContactType) -> String {
        switch type {
        case .chat: return "person.fill"
        case .repeater: return "antenna.radiowaves.left.and.right"
        case .room: return "server.rack"
        case .sensor: return "sensor.fill"
        case .unknown: return "person.fill"
        }
    }

    private func typeName(for type: ContactType) -> String {
        switch type {
        case .chat: return "Chat"
        case .repeater: return "Repeater"
        case .room: return "Room"
        case .sensor: return "Sensor"
        case .unknown: return "Unknown"
        }
    }

    private func snrColor(_ snr: Int8) -> Color {
        if snr >= 5 { return MeshTheme.connected }
        if snr >= 0 { return .yellow }
        return .orange
    }

    private func startTimedDiscovery() {
        isTimedDiscovery = true
        timeRemaining = discoveryDuration
        remoteSessionManager.discoveredNodes = []
        DebugLogger.shared.log("DISCOVER: started \(Int(discoveryDuration / 60))min timed discovery", level: .info)
        connectionManager.sendAdvertise(type: 1) // Initial flood advert

        // Re-advertise every 30 seconds
        let cm = connectionManager
        advertTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in
                cm.sendAdvertise(type: 1)
            }
        }

        // Countdown timer
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            timeRemaining -= 1
            if timeRemaining <= 0 {
                stopTimedDiscovery()
            }
        }
    }

    private func stopTimedDiscovery() {
        advertTimer?.invalidate()
        discoveryTimer?.invalidate()
        advertTimer = nil
        discoveryTimer = nil
        isTimedDiscovery = false
        timeRemaining = 0
        DebugLogger.shared.log("DISCOVER: timed discovery stopped", level: .info)
    }

    private func formatTimeRemaining(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Trace Route Result View

struct TraceRouteResultView: View {
    let result: TraceResult
    let contactName: String
    @Environment(ContactStore.self) private var contactStore
    @Environment(ConnectionManager.self) private var connectionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .foregroundStyle(MeshTheme.accent)
                Text("Trace Route to \(contactName)")
                    .font(.headline)
                    .foregroundStyle(MeshTheme.textPrimary)
            }

            if result.hops.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.right")
                        .foregroundStyle(MeshTheme.connected)
                    Text("Direct connection (no hops)")
                        .foregroundStyle(MeshTheme.textSecondary)
                }
            } else {
                VStack(spacing: 0) {
                    // Local device
                    traceNode(name: connectionManager.connectedDeviceName ?? "Local", isFirst: true, isLast: false, snr: nil)

                    ForEach(Array(result.hops.enumerated()), id: \.element.id) { index, hop in
                        traceLine(snr: hop.snr)
                        traceNode(
                            name: nodeName(for: hop.nodeHash),
                            isFirst: false,
                            isLast: index == result.hops.count - 1,
                            snr: nil
                        )
                    }
                }
            }
        }
        .padding()
        .background(MeshTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func traceNode(name: String, isFirst: Bool, isLast: Bool, snr: Int8?) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isFirst ? MeshTheme.accent : (isLast ? MeshTheme.connected : MeshTheme.textSecondary))
                .frame(width: 10, height: 10)
            Text(name)
                .font(.subheadline)
                .foregroundStyle(MeshTheme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 8)
    }

    private func traceLine(snr: Int8) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(MeshTheme.textSecondary.opacity(0.6))
                .frame(width: 2, height: 20)
                .padding(.leading, 4)
            Text("SNR \(snr)")
                .font(.caption2)
                .foregroundStyle(MeshTheme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 8)
    }

    private func nodeName(for hash: Data) -> String {
        if let contact = contactStore.contacts.first(where: { $0.publicKeyPrefix == hash }) {
            return contactStore.displayName(for: contact)
        }
        return Data(hash.prefix(4)).hexFormatted(separator: ":")
    }
}

// MARK: - Status Info View

struct StatusInfoView: View {
    let status: RemoteStatusInfo
    let contactName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "info.circle")
                    .foregroundStyle(MeshTheme.accent)
                Text("Status: \(contactName)")
                    .font(.headline)
                    .foregroundStyle(MeshTheme.textPrimary)
            }

            VStack(spacing: 8) {
                statusRow(icon: "battery.75", label: "Battery", value: batteryString)
                statusRow(icon: "clock.arrow.circlepath", label: "Uptime", value: formatUptime(status.uptime))
                statusRow(icon: "person.2", label: "Contacts", value: "\(status.contacts)")
            }
        }
        .padding()
        .background(MeshTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var batteryString: String {
        let mv = Int(status.batteryMV)
        if mv == 0 { return "\u{2014}" }
        return String(format: "%.2fV (%dmV)", Double(mv) / 1000.0, mv)
    }

    private func statusRow(icon: String, label: String, value: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(MeshTheme.accent)
                .frame(width: 20)
            Text(label)
                .foregroundStyle(MeshTheme.textPrimary)
            Spacer()
            Text(value)
                .foregroundStyle(MeshTheme.textSecondary)
        }
    }

    private func formatUptime(_ seconds: UInt32) -> String {
        let d = seconds / 86400
        let h = (seconds % 86400) / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if d > 0 { return "\(d)d \(h)h \(m)m" }
        if h > 0 { return "\(h)h \(m)m \(s)s" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}

// MARK: - Telemetry View

struct TelemetryView: View {
    let readings: [TelemetryReading]
    let contactName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .foregroundStyle(MeshTheme.accent)
                Text("Telemetry: \(contactName)")
                    .font(.headline)
                    .foregroundStyle(MeshTheme.textPrimary)
            }

            if readings.isEmpty {
                Text("No telemetry data")
                    .foregroundStyle(MeshTheme.textSecondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(readings) { reading in
                        HStack {
                            Image(systemName: telemetryIcon(for: reading.name))
                                .foregroundStyle(MeshTheme.accent)
                                .frame(width: 20)
                            Text(reading.name)
                                .foregroundStyle(MeshTheme.textPrimary)
                            Spacer()
                            if reading.name == "Altitude" {
                                Text(String(format: "%.0f m (%.0f ft)", reading.value, reading.value * 3.28084))
                                    .foregroundStyle(MeshTheme.textSecondary)
                                    .font(.system(.body, design: .monospaced))
                            } else {
                                Text(String(format: "%.1f %@", reading.value, reading.unit))
                                    .foregroundStyle(MeshTheme.textSecondary)
                                    .font(.system(.body, design: .monospaced))
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .background(MeshTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func telemetryIcon(for name: String) -> String {
        switch name.lowercased() {
        case "temperature": return "thermometer"
        case "humidity": return "humidity"
        case "pressure": return "barometer"
        case "battery": return "battery.75"
        case "illuminance": return "sun.max"
        case "altitude": return "arrow.up.to.line"
        case "gps lat", "gps lon": return "location"
        default: return "gauge"
        }
    }
}

// MARK: - Advert Path View

struct AdvertPathView: View {
    let pathInfo: AdvertPathInfo
    let contactName: String
    @Environment(ContactStore.self) private var contactStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "map")
                    .foregroundStyle(MeshTheme.accent)
                Text("Path: \(contactName)")
                    .font(.headline)
                    .foregroundStyle(MeshTheme.textPrimary)
            }

            VStack(spacing: 8) {
                HStack {
                    Text("Hops")
                        .foregroundStyle(MeshTheme.textPrimary)
                    Spacer()
                    Text("\(pathInfo.pathLen)")
                        .foregroundStyle(MeshTheme.textPrimary)
                }

                if pathInfo.recvTimestamp > 0 {
                    HStack {
                        Text("Received")
                            .foregroundStyle(MeshTheme.textPrimary)
                        Spacer()
                        Text(pathInfo.recvTimestamp.asDate, style: .relative)
                            .foregroundStyle(MeshTheme.textPrimary)
                        Text("ago")
                            .foregroundStyle(MeshTheme.textPrimary)
                    }
                }

                if !pathInfo.pathHashes.isEmpty {
                    Divider()
                    ForEach(Array(pathInfo.pathHashes.enumerated()), id: \.offset) { index, hash in
                        HStack(spacing: 8) {
                            Text("\(index + 1).")
                                .font(.caption)
                                .foregroundStyle(MeshTheme.textSecondary)
                                .frame(width: 20)
                            Text(nodeName(for: hash))
                                .font(.subheadline)
                                .foregroundStyle(MeshTheme.textPrimary)
                            Spacer()
                        }
                    }
                }
            }
        }
        .padding()
        .background(MeshTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func nodeName(for hash: Data) -> String {
        if let contact = contactStore.contacts.first(where: { $0.publicKeyPrefix == hash }) {
            return contactStore.displayName(for: contact)
        }
        if hash.count < 6 {
            if let contact = contactStore.contacts.first(where: { $0.publicKeyPrefix.prefix(hash.count) == hash }) {
                return contactStore.displayName(for: contact)
            }
        }
        return Data(hash).hexFormatted(separator: ":")
    }
}

// MARK: - Contact Detail Sheet

/// Overlay sheet showing trace route, status, telemetry, or path info for a contact.
struct ContactDetailSheet: View {
    let contact: Contact
    @Environment(ContactStore.self) private var contactStore
    @Environment(RemoteSessionManager.self) private var remoteSessionManager
    @Environment(\.dismiss) private var dismiss
    @State private var showPathEditor = false

    private var isTracePending: Bool { remoteSessionManager.pendingTraceTag != nil }
    private var isStatusPending: Bool { remoteSessionManager.pendingStatusKey == contact.publicKeyPrefix }
    private var isTelemetryPending: Bool { remoteSessionManager.pendingTelemetryKey == contact.publicKeyPrefix }
    private var isPathPending: Bool { remoteSessionManager.pendingAdvertPathKey == contact.publicKeyPrefix }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Trace Route
                    if isTracePending {
                        ActivityOverlay(message: "Tracing route to \(contactStore.displayName(for: contact))...", timeout: 15)
                            .padding()
                            .background(MeshTheme.surfaceLight)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else if let trace = remoteSessionManager.lastTraceResult {
                        TraceRouteResultView(result: trace, contactName: contactStore.displayName(for: contact))
                    }

                    // Status
                    if isStatusPending {
                        ActivityOverlay(message: statusActivityMessage, timeout: 15)
                            .padding()
                            .background(MeshTheme.surfaceLight)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else if let status = remoteSessionManager.statusByContact[contact.publicKeyPrefix] {
                        StatusInfoView(status: status, contactName: contactStore.displayName(for: contact))
                    }

                    // Telemetry
                    if isTelemetryPending {
                        ActivityOverlay(message: telemetryActivityMessage, timeout: 15)
                            .padding()
                            .background(MeshTheme.surfaceLight)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else if let readings = remoteSessionManager.telemetryByContact[contact.publicKeyPrefix], !readings.isEmpty {
                        TelemetryView(readings: readings, contactName: contactStore.displayName(for: contact))
                    }

                    // Routing Path (from contact's outPath)
                    PathViewer(contact: contact)

                    // Advert Path
                    if isPathPending {
                        ActivityOverlay(message: "Loading path info for \(contactStore.displayName(for: contact))...", timeout: 10)
                            .padding()
                            .background(MeshTheme.surfaceLight)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else if let path = remoteSessionManager.advertPathByContact[contact.publicKeyPrefix] {
                        AdvertPathView(pathInfo: path, contactName: contactStore.displayName(for: contact))
                    }

                    // Actions
                    VStack(spacing: 8) {
                        actionButton("Trace Route", icon: "point.topleft.down.to.point.bottomright.curvepath", pending: isTracePending) {
                            remoteSessionManager.traceRoute(to: contact)
                        }
                        actionButton("Request Status", icon: "info.circle", pending: isStatusPending) {
                            remoteSessionManager.requestStatus(for: contact)
                        }
                        actionButton("Request Telemetry", icon: "chart.line.uptrend.xyaxis", pending: isTelemetryPending) {
                            remoteSessionManager.requestTelemetry(for: contact)
                        }
                        actionButton("Show Path Info", icon: "map", pending: isPathPending) {
                            remoteSessionManager.requestAdvertPath(for: contact)
                        }
                        actionButton("Reset Path", icon: "arrow.counterclockwise", pending: false) {
                            contactStore.resetPath(for: contact)
                        }
                        actionButton("Edit Path", icon: "pencil.line", pending: false) {
                            showPathEditor = true
                        }
                    }
                    .foregroundStyle(MeshTheme.accent)
                }
                .padding()
            }
            .background(MeshTheme.background)
            .navigationTitle(contactStore.displayName(for: contact))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showPathEditor) {
                ManualPathEditor(contact: contact)
            }
        }
        .meshTheme()
    }

    /// Contextual status request message based on contact type.
    private var statusActivityMessage: String {
        switch contact.type {
        case .chat: return "Chat nodes don't typically support status requests. Waiting..."
        case .repeater: return "Requesting status from repeater..."
        case .room: return "Requesting status from room server..."
        default: return "Requesting status..."
        }
    }

    /// Contextual telemetry request message based on contact type.
    private var telemetryActivityMessage: String {
        switch contact.type {
        case .chat: return "Telemetry is typically only available from sensor nodes. Waiting..."
        case .repeater: return "Some repeaters support basic telemetry. Waiting..."
        case .room: return "Room servers don't typically support telemetry. Waiting..."
        default: return "Requesting telemetry from sensor..."
        }
    }

    private func actionButton(_ title: String, icon: String, pending: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                if pending {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: icon)
                }
                Text(title)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(pending)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(MeshTheme.surfaceLight)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Channel Management View

enum ChannelAction: String, CaseIterable, Identifiable {
    case hashtag = "Join Hashtag Channel"
    case createPrivate = "Create Private Channel"
    case joinPrivate = "Join Private Channel"

    var id: String { rawValue }

    var navigationTitle: String {
        switch self {
        case .hashtag: return "Join Hashtag Channel"
        case .createPrivate: return "Create Private Channel"
        case .joinPrivate: return "Join Private Channel"
        }
    }
}

struct ChannelManagementView: View {
    let action: ChannelAction
    @Environment(ChannelStore.self) private var channelStore
    @Environment(DeviceConfig.self) private var deviceConfig
    @Environment(\.dismiss) private var dismiss
    #if !os(watchOS)
    @State private var channelToShare: MeshChannel?
    #endif
    @State private var channelToRename: MeshChannel?
    @State private var renameText = ""

    @State private var channelName = ""
    @State private var secretHex = ""
    @State private var errorMessage: String?

    /// Public channel secret (well-known PSK)
    private static let publicChannelSecret = Data([
        0x8b, 0x33, 0x87, 0xe9, 0xc5, 0xcd, 0xea, 0x6a,
        0xc9, 0xe5, 0xed, 0xba, 0xa1, 0x15, 0xcd, 0x72
    ])

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: action == .hashtag ? "number" : "lock.fill")
                        .foregroundStyle(MeshTheme.accent)
                        .frame(width: 24)
                    TextField(namePlaceholder, text: $channelName)
                        .foregroundStyle(MeshTheme.textPrimary)
                        #if !os(watchOS)
                        .textFieldStyle(MeshTextFieldStyle())
                        #endif
                }
                .listRowBackground(MeshTheme.surface)

                if action == .joinPrivate {
                    HStack {
                        Image(systemName: "lock")
                            .foregroundStyle(MeshTheme.accent)
                            .frame(width: 24)
                        TextField("Secret (hex)", text: $secretHex)
                            .foregroundStyle(MeshTheme.textPrimary)
                            .font(.system(.body, design: .monospaced))
                            #if !os(watchOS)
                            .textFieldStyle(MeshTextFieldStyle())
                            #endif
                    }
                    .listRowBackground(MeshTheme.surface)
                }

                if let error = errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .listRowBackground(MeshTheme.surface)
                }

                Button {
                    joinChannel()
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(MeshTheme.accent)
                        Text(actionButtonLabel)
                            .foregroundStyle(MeshTheme.accent)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(channelName.trimmingCharacters(in: .whitespaces).isEmpty)
                .listRowBackground(MeshTheme.surface)
            } footer: {
                Text(footerText)
                    .foregroundStyle(MeshTheme.textSecondary)
                    .font(.caption2)
            }

            if !channelStore.channels.filter({ $0.index != 0 }).isEmpty {
                Section {
                    ForEach(channelStore.channels.filter { $0.index != 0 }) { channel in
                        HStack {
                            Image(systemName: channel.channelType.iconName)
                                .foregroundStyle(MeshTheme.accent)
                                .frame(width: 24)
                            Text("\(channel.channelType.displayPrefix)\(channel.name)")
                                .foregroundStyle(MeshTheme.textPrimary)
                            Spacer()
                            Text("Slot \(channel.index)")
                                .font(.caption)
                                .foregroundStyle(MeshTheme.textSecondary)
                            #if !os(watchOS)
                            Button {
                                channelToShare = channel
                            } label: {
                                Image(systemName: "qrcode")
                                    .foregroundStyle(MeshTheme.accent)
                            }
                            .buttonStyle(.plain)
                            #endif
                            Button {
                                removeChannel(channel)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(MeshTheme.disconnected)
                            }
                            .buttonStyle(.plain)
                        }
                        .listRowBackground(MeshTheme.surface)
                        .contextMenu {
                            Button {
                                channelToRename = channel
                                renameText = channel.name
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            #if !os(watchOS)
                            Button {
                                channelToShare = channel
                            } label: {
                                Label("Share QR Code", systemImage: "qrcode")
                            }
                            #endif
                            Divider()
                            Button(role: .destructive) {
                                removeChannel(channel)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("Active Channels")
                        .foregroundStyle(MeshTheme.textSecondary)
                }
            }
        }
        .meshListStyle()
        .navigationTitle(action.navigationTitle)
        #if !os(watchOS)
        .sheet(item: $channelToShare) { channel in
            ShareChannelSheet(channel: channel)
                .frame(minWidth: 360, minHeight: 400)
        }
        #endif
        .alert("Rename Channel", isPresented: Binding(
            get: { channelToRename != nil },
            set: { if !$0 { channelToRename = nil } }
        )) {
            TextField("Channel name", text: $renameText)
            Button("Cancel", role: .cancel) { channelToRename = nil }
            Button("Rename") {
                if let ch = channelToRename, !renameText.isEmpty {
                    channelStore.setChannel(index: ch.index, name: renameText, secret: ch.secret)
                }
                channelToRename = nil
            }
        } message: {
            Text("Enter a new name for this channel.")
        }
    }

    private var namePlaceholder: String {
        switch action {
        case .hashtag: return "#channel-name"
        case .createPrivate: return "Channel name"
        case .joinPrivate: return "Channel name"
        }
    }

    private var footerText: String {
        switch action {
        case .hashtag:
            return "Hashtag channels derive their encryption key from the channel name. Anyone who knows the name can join."
        case .createPrivate:
            return "Creates a channel with a random 128-bit encryption key. Share the key with others to let them join."
        case .joinPrivate:
            return "Enter the channel name and the shared hex secret to join an existing private channel."
        }
    }

    private var actionButtonLabel: String {
        switch action {
        case .hashtag:
            let name = channelName.trimmingCharacters(in: .whitespaces)
            let display = name.hasPrefix("#") ? name : "#\(name)"
            return name.isEmpty ? "Join" : "Join \(display)"
        case .createPrivate:
            return "Create Channel"
        case .joinPrivate:
            return "Join Channel"
        }
    }

    private func joinChannel() {
        let name = channelName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        errorMessage = nil

        // Find first empty slot (skip slot 0 = public channel)
        let maxCh = Int(deviceConfig.maxChannels)
        let usedIndices = Set(channelStore.channels.map { $0.index })
        guard let freeSlot = (1..<maxCh).first(where: { !usedIndices.contains(UInt8($0)) }) else {
            errorMessage = "No free channel slots available."
            return
        }

        let secret: Data
        switch action {
        case .hashtag:
            // Derive secret from channel name by hashing
            let hashName = name.hasPrefix("#") ? name : "#\(name)"
            secret = deriveHashChannelSecret(hashName)
            let displayName = hashName
            channelStore.setChannel(index: UInt8(freeSlot), name: displayName, secret: secret)

        case .createPrivate:
            // Generate random 16-byte (128-bit) secret
            var randomBytes = [UInt8](repeating: 0, count: 16)
            _ = SecRandomCopyBytes(kSecRandomDefault, 16, &randomBytes)
            secret = Data(randomBytes)
            channelStore.setChannel(index: UInt8(freeSlot), name: name, secret: secret)

        case .joinPrivate:
            let hex = secretHex.trimmingCharacters(in: .whitespaces)
            guard let parsed = Data(hexString: hex), parsed.count == 16 else {
                errorMessage = "Secret must be exactly 16 bytes (32 hex characters)."
                return
            }
            secret = parsed
            channelStore.setChannel(index: UInt8(freeSlot), name: name, secret: secret)
        }

        channelName = ""
        secretHex = ""
    }

    private func removeChannel(_ channel: MeshChannel) {
        channelStore.setChannel(index: channel.index, name: "", secret: nil)
    }

    /// Derive a channel secret from a hashtag name by hashing (SHA-256).
    private func deriveHashChannelSecret(_ name: String) -> Data {
        guard let nameData = name.data(using: .utf8) else { return Data(repeating: 0, count: 16) }
        let digest = SHA256.hash(data: nameData)
        return Data(digest.prefix(16))  // 128-bit PSK from first 16 bytes of SHA-256
    }
}

// MARK: - Hex String Data Extension

private extension Data {
    init?(hexString: String) {
        let hex = hexString.replacingOccurrences(of: " ", with: "")
        guard hex.count % 2 == 0 else { return nil }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}

// MARK: - Device Info Popover

/// Shows basic info about the currently connected device.
struct DeviceInfoPopover: View {
    @Environment(DeviceConfig.self) private var config
    @Environment(ContactStore.self) private var contactStore
    @Environment(ChannelStore.self) private var channelStore
    @Environment(ConnectionManager.self) private var connectionManager

    var body: some View {
        List {
            Section {
                infoRow("Device", value: connectionManager.connectedDeviceName ?? "Unknown")
                if !config.advertName.isEmpty {
                    infoRow("Advert Name", value: config.advertName)
                }
                if !config.semanticVersion.isEmpty {
                    infoRow("Firmware", value: config.semanticVersion)
                } else if !config.firmwareVersion.isEmpty {
                    infoRow("Firmware", value: config.firmwareVersion)
                }
                if !config.manufacturer.isEmpty {
                    infoRow("Model", value: config.manufacturer)
                }
            } header: {
                Text("Device").foregroundStyle(MeshTheme.textSecondary)
            }

            Section {
                if config.batteryMillivolts > 0 {
                    infoRow("Battery", value: String(format: "%.2fV (%d%%)", config.batteryVoltage, config.batteryPercent()))
                }
                if config.statsUptime > 0 {
                    infoRow("Uptime", value: formatUptime(config.statsUptime))
                }
                if config.statsLastRSSI != 0 {
                    infoRow("Last RSSI", value: "\(config.statsLastRSSI) dBm")
                }
                if config.statsLastSNR != 0 {
                    infoRow("Last SNR", value: formatSNR(config.statsLastSNR))
                }
            } header: {
                Text("Status").foregroundStyle(MeshTheme.textSecondary)
            }

            Section {
                infoRow("Frequency", value: String(format: "%.1f MHz", config.frequencyMHz))
                infoRow("TX Power", value: "\(config.radioTXPower) dBm")
                infoRow("SF/BW", value: "SF\(config.radioSpreadingFactor) / \(Int(config.bandwidthKHz)) kHz")
                infoRow("Contacts", value: "\(contactStore.contacts.count) / \(config.maxContacts)")
                infoRow("Channels", value: "\(channelStore.channels.count) / \(config.maxChannels)")
            } header: {
                Text("Radio").foregroundStyle(MeshTheme.textSecondary)
            }

            Section {
                Button(role: .destructive) {
                    connectionManager.bleManager.disconnect()
                } label: {
                    HStack {
                        Image(systemName: "wifi.slash")
                        Text("Disconnect")
                        Spacer()
                    }
                    .foregroundStyle(.red)
                }
                .listRowBackground(MeshTheme.surface)
            }
        }
        .meshListStyle()
        .navigationTitle("Device Info")
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(MeshTheme.accent)
            Spacer()
            Text(value)
                .foregroundStyle(MeshTheme.textPrimary)
        }
        .listRowBackground(MeshTheme.surface)
    }

    private func formatUptime(_ seconds: UInt32) -> String {
        let d = seconds / 86400
        let h = (seconds % 86400) / 3600
        let m = (seconds % 3600) / 60
        if d > 0 { return "\(d)d \(h)h \(m)m" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

// MARK: - Activity Overlay

/// Reusable activity indicator with message and elapsed time counter.
struct ActivityOverlay: View {
    let message: String
    let timeout: TimeInterval
    @State private var elapsed: TimeInterval = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(MeshTheme.textSecondary)
            Spacer()
            Text("\(Int(elapsed))s / \(Int(timeout))s")
                .font(.caption)
                .foregroundStyle(MeshTheme.textSecondary)
        }
        .onReceive(timer) { _ in
            if elapsed < timeout { elapsed += 1 }
        }
    }
}

// MARK: - Path Viewer

struct PathViewer: View {
    let contact: Contact
    @Environment(ContactStore.self) private var contactStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .foregroundStyle(MeshTheme.accent)
                Text("Routing Path")
                    .font(.headline)
                    .foregroundStyle(MeshTheme.textPrimary)
            }

            if contact.outPathLen == 0 {
                Label("Direct neighbor (0 hops)", systemImage: "arrow.right")
                    .foregroundStyle(MeshTheme.connected)
            } else if contact.outPathLen < 0 {
                Label("No known path \u{2014} messages will flood", systemImage: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.orange)
            } else {
                let hops = parsePathHops(from: contact.outPath, pathLen: Int(contact.outPathLen))

                // Visual path
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        pathNode("You", color: MeshTheme.interactiveGreen)
                        ForEach(Array(hops.enumerated()), id: \.offset) { _, hop in
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundStyle(MeshTheme.textSecondary)
                            pathNode(hop, color: MeshTheme.surfaceLight)
                        }
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(MeshTheme.textSecondary)
                        pathNode(contactStore.displayName(for: contact), color: MeshTheme.incomingBubble)
                    }
                }

                Text("\(hops.count) hop\(hops.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(MeshTheme.textSecondary)
            }
        }
        .padding()
        .background(MeshTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func pathNode(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(.caption, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(MeshTheme.textPrimary)
    }

    private func parsePathHops(from pathData: Data, pathLen: Int) -> [String] {
        guard !pathData.isEmpty, pathLen > 0 else { return [] }
        let bytesPerHop = max(1, min(3, pathData.count / pathLen))
        var hops: [String] = []
        for i in 0..<pathLen {
            let start = i * bytesPerHop
            let end = min(start + bytesPerHop, pathData.count)
            guard end <= pathData.count else { break }
            let hashBytes = Data(pathData[start..<end])
            if let name = resolvePathHash(hashBytes) {
                hops.append(name)
            } else {
                hops.append(Data(hashBytes).hexCompact.uppercased())
            }
        }
        return hops
    }

    private func resolvePathHash(_ hashBytes: Data) -> String? {
        for c in contactStore.contacts where c.type == .repeater {
            if c.publicKeyPrefix.prefix(hashBytes.count) == hashBytes {
                return contactStore.displayName(for: c)
            }
        }
        return nil
    }
}

// MARK: - Manual Path Editor

struct ManualPathEditor: View {
    let contact: Contact
    @Environment(ContactStore.self) private var contactStore
    @Environment(\.dismiss) private var dismiss
    @State private var pathMode = 0 // 0=auto, 1=flood, 2=manual
    @State private var selectedRepeaters: [Contact] = []
    @State private var manualPathHex = ""
    @State private var pathApplied = false

    private var repeaters: [Contact] {
        contactStore.contacts.filter { $0.type == .repeater }
    }

    var body: some View {
        NavigationStack {
            Form {
                modePickerSection
                if pathMode == 2 {
                    repeaterSelectionSection
                    pathOrderSection
                    manualHexSection
                }
            }
            .navigationTitle("Edit Path")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(pathApplied ? "Done" : "Apply") {
                        if pathApplied {
                            dismiss()
                        } else {
                            applyPath()
                            pathApplied = true
                            // Auto-dismiss after a brief delay so user sees confirmation
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { dismiss() }
                        }
                    }
                    .foregroundStyle(pathApplied ? MeshTheme.connected : MeshTheme.accent)
                }
            }
            .onAppear {
                // Initialize mode from current contact state
                if contact.outPathLen < 0 {
                    pathMode = 1 // Flood
                } else if contact.outPathLen > 0 {
                    pathMode = 2 // Manual
                } else {
                    pathMode = 0 // Auto/Direct
                }
            }
        }
    }

    private var modePickerSection: some View {
        Section {
            Picker("Routing Mode", selection: $pathMode) {
                Text("Auto (device discovers path)").tag(0)
                Text("Flood (broadcast to all)").tag(1)
                Text("Manual (select repeaters)").tag(2)
            }
            .pickerStyle(.inline)
        }
    }

    private var repeaterSelectionSection: some View {
        Section("Select Repeaters") {
            if repeaters.isEmpty {
                Text("No repeaters discovered")
                    .font(.caption)
                    .foregroundStyle(MeshTheme.textSecondary)
            }
            ForEach(repeaters) { repeater in
                let isSelected = selectedRepeaters.contains(where: { $0.publicKey == repeater.publicKey })
                Button { toggleRepeater(repeater) } label: {
                    HStack {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? MeshTheme.accent : MeshTheme.textSecondary)
                        Text(contactStore.displayName(for: repeater))
                            .foregroundStyle(MeshTheme.textPrimary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var pathOrderSection: some View {
        if !selectedRepeaters.isEmpty {
            Section("Path Order") {
                ForEach(Array(selectedRepeaters.enumerated()), id: \.element.publicKey) { idx, rep in
                    HStack {
                        Text("\(idx + 1).")
                            .foregroundStyle(MeshTheme.textSecondary)
                        Text(contactStore.displayName(for: rep))
                            .foregroundStyle(MeshTheme.textPrimary)
                    }
                }
                .onMove { from, to in
                    selectedRepeaters.move(fromOffsets: from, toOffset: to)
                }
            }
        }
    }

    private var manualHexSection: some View {
        Section {
            TextField("Hex hops (e.g., A3,B7,4F)", text: $manualPathHex)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(MeshTheme.textPrimary)
        } header: {
            Text("Or Enter Path Manually")
        } footer: {
            Text("Enter repeater hashes separated by commas.")
                .font(.caption2)
        }
    }

    private func toggleRepeater(_ repeater: Contact) {
        if let idx = selectedRepeaters.firstIndex(where: { $0.publicKey == repeater.publicKey }) {
            selectedRepeaters.remove(at: idx)
        } else {
            selectedRepeaters.append(repeater)
        }
    }

    private func applyPath() {
        switch pathMode {
        case 1: // Flood
            contactStore.setContactPath(contact, pathLen: -1, pathData: Data())
        case 2: // Manual
            if !selectedRepeaters.isEmpty {
                var pathData = Data()
                for rep in selectedRepeaters {
                    pathData.append(rep.publicKeyPrefix.prefix(1)) // 1-byte hash
                }
                contactStore.setContactPath(contact, pathLen: Int8(selectedRepeaters.count), pathData: pathData)
            } else if !manualPathHex.isEmpty {
                let hexParts = manualPathHex.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                var pathData = Data()
                for hex in hexParts {
                    var bytes = Data()
                    var chars = hex[hex.startIndex...]
                    while chars.count >= 2 {
                        if let byte = UInt8(String(chars.prefix(2)), radix: 16) {
                            bytes.append(byte)
                        }
                        chars = chars.dropFirst(2)
                    }
                    pathData.append(bytes)
                }
                contactStore.setContactPath(contact, pathLen: Int8(hexParts.count), pathData: pathData)
            }
        default: // Auto — reset path so device rediscovers
            contactStore.resetPath(for: contact)
        }
    }
}
