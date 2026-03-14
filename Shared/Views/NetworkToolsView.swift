import SwiftUI
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
                            .foregroundStyle(MeshTheme.accentFallback)
                            .frame(width: 24)
                        Text(viewModel.isDiscovering ? "Scanning..." : "Start Discover")
                            .foregroundStyle(MeshTheme.accentFallback)
                        Spacer()
                        if viewModel.isDiscovering {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(MeshTheme.surface)
            }

            if viewModel.discoveredNodes.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "sensor.tag.radiowaves.forward")
                                .font(.system(size: 36))
                                .foregroundStyle(MeshTheme.textSecondary.opacity(0.5))
                            Text("No nodes discovered")
                                .font(.subheadline)
                                .foregroundStyle(MeshTheme.textSecondary)
                            Text("Tap Start Discover to scan the mesh")
                                .font(.caption)
                                .foregroundStyle(MeshTheme.textSecondary.opacity(0.7))
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
                    .fill(MeshTheme.accentFallback.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: iconName(for: node.type))
                    .foregroundStyle(MeshTheme.accentFallback)
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
        case .unknown: return "questionmark"
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
                    .foregroundStyle(MeshTheme.accentFallback)
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
                .fill(isFirst ? MeshTheme.accentFallback : (isLast ? MeshTheme.connected : MeshTheme.textSecondary))
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
                .fill(MeshTheme.textSecondary.opacity(0.4))
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
        // Try to match hash to a known contact
        if let contact = viewModel.contacts.first(where: { $0.publicKeyPrefix == hash }) {
            return contact.name
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
                    .foregroundStyle(MeshTheme.accentFallback)
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
                .foregroundStyle(MeshTheme.accentFallback)
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
                    .foregroundStyle(MeshTheme.accentFallback)
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
                                .foregroundStyle(MeshTheme.accentFallback)
                                .frame(width: 20)
                            Text(reading.name)
                                .foregroundStyle(MeshTheme.textPrimary)
                            Spacer()
                            Text(String(format: "%.1f %@", reading.value, reading.unit))
                                .foregroundStyle(MeshTheme.textSecondary)
                                .font(.system(.body, design: .monospaced))
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
                    .foregroundStyle(MeshTheme.accentFallback)
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
                        .foregroundStyle(MeshTheme.textSecondary)
                }

                if pathInfo.recvTimestamp > 0 {
                    HStack {
                        Text("Received")
                            .foregroundStyle(MeshTheme.textPrimary)
                        Spacer()
                        Text(Date(timeIntervalSince1970: TimeInterval(pathInfo.recvTimestamp)), style: .relative)
                            .foregroundStyle(MeshTheme.textSecondary)
                        Text("ago")
                            .foregroundStyle(MeshTheme.textSecondary)
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
        if let contact = viewModel.contacts.first(where: { $0.publicKeyPrefix == hash }) {
            return contact.name
        }
        return hash.prefix(4).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

// MARK: - Contact Detail Sheet

/// Overlay sheet showing trace route, status, telemetry, or path info for a contact.
struct ContactDetailSheet: View {
    let contact: Contact
    @EnvironmentObject var viewModel: MeshCoreViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Trace Route
                    if let trace = viewModel.lastTraceResult {
                        TraceRouteResultView(result: trace, contactName: contact.name)
                    }

                    // Status
                    if let status = viewModel.statusByContact[contact.publicKeyPrefix] {
                        StatusInfoView(status: status, contactName: contact.name)
                    }

                    // Telemetry
                    if let readings = viewModel.telemetryByContact[contact.publicKeyPrefix], !readings.isEmpty {
                        TelemetryView(readings: readings, contactName: contact.name)
                    }

                    // Advert Path
                    if let path = viewModel.advertPathByContact[contact.publicKeyPrefix] {
                        AdvertPathView(pathInfo: path, contactName: contact.name)
                    }

                    // Actions
                    VStack(spacing: 8) {
                        Button {
                            viewModel.traceRoute(to: contact)
                        } label: {
                            Label("Trace Route", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 8)
                        .background(MeshTheme.surfaceLight)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        Button {
                            viewModel.requestStatus(for: contact)
                        } label: {
                            Label("Request Status", systemImage: "info.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 8)
                        .background(MeshTheme.surfaceLight)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        Button {
                            viewModel.requestTelemetry(for: contact)
                        } label: {
                            Label("Request Telemetry", systemImage: "chart.line.uptrend.xyaxis")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 8)
                        .background(MeshTheme.surfaceLight)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        Button {
                            viewModel.requestAdvertPath(for: contact)
                        } label: {
                            Label("Show Path Info", systemImage: "map")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 8)
                        .background(MeshTheme.surfaceLight)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .foregroundStyle(MeshTheme.accentFallback)
                }
                .padding()
            }
            .background(MeshTheme.background)
            .navigationTitle(contact.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .meshTheme()
    }
}
