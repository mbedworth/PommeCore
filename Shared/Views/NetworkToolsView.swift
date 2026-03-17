import SwiftUI
import CryptoKit
import MeshCoreKit

// MARK: - Discover View

struct DiscoverView: View {
    @EnvironmentObject var viewModel: MeshCoreViewModel

    var body: some View {
        List {
            Section {
                Button {
                    viewModel.startDiscover()
                } label: {
                    HStack {
                        Image(systemName: "magnifyingglass.circle")
                            .foregroundStyle(MeshTheme.accent)
                            .frame(width: 24)
                        Text(viewModel.isDiscovering ? "Scanning..." : "Start Discover")
                            .foregroundStyle(MeshTheme.accent)
                        Spacer()
                        if viewModel.isDiscovering {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isDiscovering)
                .listRowBackground(MeshTheme.surface)

                if viewModel.isDiscovering {
                    ActivityOverlay(message: "Scanning for nearby nodes...", timeout: 30)
                        .listRowBackground(MeshTheme.surface)
                }

                if let fallbackMsg = viewModel.discoverFallbackMessage {
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

            if viewModel.discoveredNodes.isEmpty {
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
                    ForEach(viewModel.discoveredNodes) { node in
                        discoveredNodeRow(node)
                    }
                } header: {
                    Text("\(viewModel.discoveredNodes.count) Node\(viewModel.discoveredNodes.count == 1 ? "" : "s") Found")
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
        case .unknown: return "person.fill"
        }
    }

    private func typeName(for type: ContactType) -> String {
        switch type {
        case .chat: return "Chat"
        case .repeater: return "Repeater"
        case .room: return "Room"
        case .unknown: return "Unknown"
        }
    }

    private func snrColor(_ snr: Int8) -> Color {
        if snr >= 5 { return MeshTheme.connected }
        if snr >= 0 { return .yellow }
        return .orange
    }
}

// MARK: - Trace Route Result View

struct TraceRouteResultView: View {
    let result: TraceResult
    let contactName: String
    @EnvironmentObject var viewModel: MeshCoreViewModel

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
                    traceNode(name: viewModel.connectedDeviceName ?? "Local", isFirst: true, isLast: false, snr: nil)

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
        // Try to match hash to a known contact (use nickname if set)
        if let contact = viewModel.contacts.first(where: { $0.publicKeyPrefix == hash }) {
            return viewModel.displayName(for: contact)
        }
        return hash.prefix(4).map { String(format: "%02X", $0) }.joined(separator: ":")
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
    @EnvironmentObject var viewModel: MeshCoreViewModel

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
                        Text(Date(timeIntervalSince1970: TimeInterval(pathInfo.recvTimestamp)), style: .relative)
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
        // Try exact 6-byte match first
        if let contact = viewModel.contacts.first(where: { $0.publicKeyPrefix == hash }) {
            return viewModel.displayName(for: contact)
        }
        // Try prefix match for smaller hashes (1-3 byte path hash mode)
        if hash.count < 6 {
            if let contact = viewModel.contacts.first(where: { $0.publicKeyPrefix.prefix(hash.count) == hash }) {
                return viewModel.displayName(for: contact)
            }
        }
        return hash.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

// MARK: - Contact Detail Sheet

/// Overlay sheet showing trace route, status, telemetry, or path info for a contact.
struct ContactDetailSheet: View {
    let contact: Contact
    @EnvironmentObject var viewModel: MeshCoreViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showPathEditor = false

    private var isTracePending: Bool { viewModel.pendingTraceTag != nil }
    private var isStatusPending: Bool { viewModel.pendingStatusKey == contact.publicKeyPrefix }
    private var isTelemetryPending: Bool { viewModel.pendingTelemetryKey == contact.publicKeyPrefix }
    private var isPathPending: Bool { viewModel.pendingAdvertPathKey == contact.publicKeyPrefix }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Trace Route
                    if isTracePending {
                        ActivityOverlay(message: "Tracing route to \(viewModel.displayName(for: contact))...", timeout: 15)
                            .padding()
                            .background(MeshTheme.surfaceLight)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else if let trace = viewModel.lastTraceResult {
                        TraceRouteResultView(result: trace, contactName: viewModel.displayName(for: contact))
                    }

                    // Status
                    if isStatusPending {
                        ActivityOverlay(message: statusActivityMessage, timeout: 15)
                            .padding()
                            .background(MeshTheme.surfaceLight)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else if let status = viewModel.statusByContact[contact.publicKeyPrefix] {
                        StatusInfoView(status: status, contactName: viewModel.displayName(for: contact))
                    }

                    // Telemetry
                    if isTelemetryPending {
                        ActivityOverlay(message: telemetryActivityMessage, timeout: 15)
                            .padding()
                            .background(MeshTheme.surfaceLight)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else if let readings = viewModel.telemetryByContact[contact.publicKeyPrefix], !readings.isEmpty {
                        TelemetryView(readings: readings, contactName: viewModel.displayName(for: contact))
                    }

                    // Routing Path (from contact's outPath)
                    PathViewer(contact: contact)

                    // Advert Path
                    if isPathPending {
                        ActivityOverlay(message: "Loading path info for \(viewModel.displayName(for: contact))...", timeout: 10)
                            .padding()
                            .background(MeshTheme.surfaceLight)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else if let path = viewModel.advertPathByContact[contact.publicKeyPrefix] {
                        AdvertPathView(pathInfo: path, contactName: viewModel.displayName(for: contact))
                    }

                    // Actions
                    VStack(spacing: 8) {
                        actionButton("Trace Route", icon: "point.topleft.down.to.point.bottomright.curvepath", pending: isTracePending) {
                            viewModel.traceRoute(to: contact)
                        }
                        actionButton("Request Status", icon: "info.circle", pending: isStatusPending) {
                            viewModel.requestStatus(for: contact)
                        }
                        actionButton("Request Telemetry", icon: "chart.line.uptrend.xyaxis", pending: isTelemetryPending) {
                            viewModel.requestTelemetry(for: contact)
                        }
                        actionButton("Show Path Info", icon: "map", pending: isPathPending) {
                            viewModel.requestAdvertPath(for: contact)
                        }
                        actionButton("Reset Path", icon: "arrow.counterclockwise", pending: false) {
                            viewModel.resetPath(for: contact)
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
            .navigationTitle(viewModel.displayName(for: contact))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showPathEditor) {
                ManualPathEditor(contact: contact)
                    .environmentObject(viewModel)
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

struct ChannelManagementView: View {
    @EnvironmentObject var viewModel: MeshCoreViewModel
    @Environment(\.dismiss) private var dismiss
    #if !os(watchOS)
    @State private var channelToShare: MeshChannel?
    #endif
    @State private var channelToRename: MeshChannel?
    @State private var renameText = ""

    enum ChannelAction: String, CaseIterable, Identifiable {
        case hashtag = "Join Hashtag Channel"
        case createPrivate = "Create Private Channel"
        case joinPrivate = "Join Private Channel"

        var id: String { rawValue }
    }

    @State private var selectedAction: ChannelAction = .hashtag
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
                Picker("Action", selection: $selectedAction) {
                    ForEach(ChannelAction.allCases) { action in
                        Text(action.rawValue).tag(action)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(MeshTheme.surface)
            }

            Section {
                HStack {
                    Image(systemName: "number")
                        .foregroundStyle(MeshTheme.accent)
                        .frame(width: 24)
                    TextField(namePlaceholder, text: $channelName)
                        .foregroundStyle(MeshTheme.textPrimary)
                        #if !os(watchOS)
                        .textFieldStyle(MeshTextFieldStyle())
                        #endif
                }
                .listRowBackground(MeshTheme.surface)

                if selectedAction == .joinPrivate {
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
            } header: {
                Text("New Channel")
                    .foregroundStyle(MeshTheme.textSecondary)
            } footer: {
                Text(footerText)
                    .foregroundStyle(MeshTheme.textSecondary)
                    .font(.caption2)
            }

            if !viewModel.channels.filter({ $0.index != 0 }).isEmpty {
                Section {
                    ForEach(viewModel.channels.filter { $0.index != 0 }) { channel in
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
        .navigationTitle("Channels")
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
                    viewModel.setChannel(index: ch.index, name: renameText, secret: ch.secret)
                }
                channelToRename = nil
            }
        } message: {
            Text("Enter a new name for this channel.")
        }
    }

    private var namePlaceholder: String {
        switch selectedAction {
        case .hashtag: return "#channel-name"
        case .createPrivate: return "Channel name"
        case .joinPrivate: return "Channel name"
        }
    }

    private var footerText: String {
        switch selectedAction {
        case .hashtag:
            return "Hashtag channels derive their encryption key from the channel name. Anyone who knows the name can join."
        case .createPrivate:
            return "Creates a channel with a random 128-bit encryption key. Share the key with others to let them join."
        case .joinPrivate:
            return "Enter the channel name and the shared hex secret to join an existing private channel."
        }
    }

    private var actionButtonLabel: String {
        switch selectedAction {
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
        let maxCh = Int(viewModel.deviceConfig.maxChannels)
        let usedIndices = Set(viewModel.channels.map { $0.index })
        guard let freeSlot = (1..<maxCh).first(where: { !usedIndices.contains(UInt8($0)) }) else {
            errorMessage = "No free channel slots available."
            return
        }

        let secret: Data
        switch selectedAction {
        case .hashtag:
            // Derive secret from channel name by hashing
            let hashName = name.hasPrefix("#") ? name : "#\(name)"
            secret = deriveHashChannelSecret(hashName)
            let displayName = hashName
            viewModel.setChannel(index: UInt8(freeSlot), name: displayName, secret: secret)

        case .createPrivate:
            // Generate random 16-byte (128-bit) secret
            var randomBytes = [UInt8](repeating: 0, count: 16)
            _ = SecRandomCopyBytes(kSecRandomDefault, 16, &randomBytes)
            secret = Data(randomBytes)
            viewModel.setChannel(index: UInt8(freeSlot), name: name, secret: secret)

        case .joinPrivate:
            let hex = secretHex.trimmingCharacters(in: .whitespaces)
            guard let parsed = Data(hexString: hex), parsed.count == 16 else {
                errorMessage = "Secret must be exactly 16 bytes (32 hex characters)."
                return
            }
            secret = parsed
            viewModel.setChannel(index: UInt8(freeSlot), name: name, secret: secret)
        }

        channelName = ""
        secretHex = ""
    }

    private func removeChannel(_ channel: MeshChannel) {
        viewModel.setChannel(index: channel.index, name: "", secret: nil)
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
    @EnvironmentObject var viewModel: MeshCoreViewModel

    private var config: DeviceConfig { viewModel.deviceConfig }

    var body: some View {
        List {
            Section {
                infoRow("Device", value: viewModel.connectedDeviceName ?? "Unknown")
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
                    infoRow("Last SNR", value: String(format: "%.1f dB", Double(config.statsLastSNR) / 4.0))
                }
            } header: {
                Text("Status").foregroundStyle(MeshTheme.textSecondary)
            }

            Section {
                infoRow("Frequency", value: String(format: "%.1f MHz", config.frequencyMHz))
                infoRow("TX Power", value: "\(config.radioTXPower) dBm")
                infoRow("SF/BW", value: "SF\(config.radioSpreadingFactor) / \(Int(config.bandwidthKHz)) kHz")
                infoRow("Contacts", value: "\(viewModel.contacts.count) / \(config.maxContacts)")
                infoRow("Channels", value: "\(viewModel.channels.count) / \(config.maxChannels)")
            } header: {
                Text("Radio").foregroundStyle(MeshTheme.textSecondary)
            }

            Section {
                Button(role: .destructive) {
                    viewModel.disconnect()
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
    @EnvironmentObject var viewModel: MeshCoreViewModel

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
                        pathNode(viewModel.displayName(for: contact), color: MeshTheme.incomingBubble)
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
        // Infer bytes per hop from data length and hop count
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
                hops.append(hashBytes.map { String(format: "%02X", $0) }.joined())
            }
        }
        return hops
    }

    /// Try to match a path hash to a known repeater name.
    private func resolvePathHash(_ hashBytes: Data) -> String? {
        for c in viewModel.contacts where c.type == .repeater {
            if c.publicKeyPrefix.prefix(hashBytes.count) == hashBytes {
                return viewModel.displayName(for: c)
            }
        }
        return nil
    }
}

// MARK: - Manual Path Editor

struct ManualPathEditor: View {
    let contact: Contact
    @EnvironmentObject var viewModel: MeshCoreViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var pathMode = 0 // 0=auto, 1=flood, 2=manual
    @State private var selectedRepeaters: [Contact] = []
    @State private var manualPathHex = ""
    @State private var pathApplied = false

    private var repeaters: [Contact] {
        viewModel.contacts.filter { $0.type == .repeater }
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
                        }
                    }
                    .foregroundStyle(pathApplied ? MeshTheme.connected : MeshTheme.accent)
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
                        Text(viewModel.displayName(for: repeater))
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
                        Text(viewModel.displayName(for: rep))
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
            viewModel.setContactPath(contact, pathLen: -1, pathData: Data())
        case 2: // Manual
            if !selectedRepeaters.isEmpty {
                var pathData = Data()
                for rep in selectedRepeaters {
                    pathData.append(rep.publicKeyPrefix.prefix(1)) // 1-byte hash
                }
                viewModel.setContactPath(contact, pathLen: Int8(selectedRepeaters.count), pathData: pathData)
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
                viewModel.setContactPath(contact, pathLen: Int8(hexParts.count), pathData: pathData)
            }
        default: // Auto — reset path so device rediscovers
            viewModel.resetPath(for: contact)
        }
    }
}
