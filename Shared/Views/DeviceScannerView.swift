import SwiftUI
import MeshCoreKit

struct DeviceScannerView: View {
    @EnvironmentObject var viewModel: MeshCoreViewModel
    @Environment(\.dismiss) private var dismiss

    /// Tracks the scan cycle timer while the view is visible.
    @State private var scanCycleTask: Task<Void, Never>?
    @State private var wifiHost = ""
    @State private var wifiPort = "5000"
    @AppStorage("savedWiFiConnections") private var savedWiFiData: Data = Data()
    #if os(macOS)
    @State private var manualSerialPort = ""
    #endif

    var body: some View {
        List {
            Section {
                if viewModel.discoveredPeripherals.isEmpty {
                    if viewModel.isScanning {
                        HStack(spacing: 12) {
                            ProgressView()
                                .tint(MeshTheme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Searching for MeshCore devices...")
                                    .foregroundStyle(MeshTheme.textPrimary)
                                if viewModel.scanRetryCount < 3 && viewModel.scanRetryCount > 0 {
                                    Text("Retry \(3 - viewModel.scanRetryCount) of 3")
                                        .font(.caption)
                                        .foregroundStyle(MeshTheme.textSecondary)
                                }
                            }
                        }
                        .listRowBackground(MeshTheme.surface)
                    } else {
                        Button {
                            viewModel.scanRetryCount = 3
                            viewModel.startScanning()
                            startScanCycle()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                                    .foregroundStyle(MeshTheme.textSecondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("No devices found")
                                        .foregroundStyle(MeshTheme.textPrimary)
                                    Text("Tap to scan again")
                                        .font(.caption)
                                        .foregroundStyle(MeshTheme.accent)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(MeshTheme.surface)
                    }
                } else {
                    // Show scanning indicator above the device list
                    if viewModel.isScanning {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.7)
                                .tint(MeshTheme.accent)
                            Text("Scanning...")
                                .font(.caption)
                                .foregroundStyle(MeshTheme.textSecondary)
                        }
                        .listRowBackground(MeshTheme.surface)
                    }

                    ForEach(viewModel.discoveredPeripherals) { peripheral in
                        Button {
                            viewModel.connect(to: peripheral)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(MeshTheme.accent.opacity(0.12))
                                        .frame(width: 40, height: 40)
                                    Image(systemName: "radio")
                                        .foregroundStyle(MeshTheme.accent)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(peripheral.name)
                                        .font(.body)
                                        .foregroundStyle(MeshTheme.textPrimary)
                                    Text("\(peripheral.rssi) dBm")
                                        .font(.caption)
                                        .foregroundStyle(MeshTheme.textSecondary)
                                }
                                Spacer()
                                signalBars(rssi: peripheral.rssi)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(MeshTheme.surface)
                    }
                }
            } header: {
                Text("Nearby Devices")
                    .foregroundStyle(MeshTheme.textSecondary)
            }

            Section {
                if viewModel.wifiManager.isConnected {
                    HStack {
                        Image(systemName: "wifi")
                            .foregroundStyle(MeshTheme.connected)
                        Text(viewModel.wifiManager.connectedHost ?? "Connected")
                            .foregroundStyle(MeshTheme.textPrimary)
                        Spacer()
                        Button("Disconnect") {
                            viewModel.disconnectWiFi()
                        }
                        .foregroundStyle(MeshTheme.disconnected)
                    }
                    .listRowBackground(MeshTheme.surface)
                } else {
                    // Saved connections
                    ForEach(savedWiFiConnections) { saved in
                        Button {
                            viewModel.connectWiFi(host: saved.host, port: saved.port)
                            saveWiFiConnection(host: saved.host, port: saved.port)
                        } label: {
                            HStack {
                                Image(systemName: "wifi")
                                    .foregroundStyle(MeshTheme.accent)
                                VStack(alignment: .leading) {
                                    Text("\(saved.host):\(saved.port)")
                                        .foregroundStyle(MeshTheme.textPrimary)
                                    Text(saved.lastConnected, style: .relative)
                                        .font(.caption2)
                                        .foregroundStyle(MeshTheme.textSecondary)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(MeshTheme.surface)
                        .swipeActions {
                            Button(role: .destructive) {
                                removeWiFiConnection(saved)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }

                    // Manual entry
                    HStack(spacing: 8) {
                        Image(systemName: "wifi")
                            .foregroundStyle(MeshTheme.accent)
                        TextField("IP Address", text: $wifiHost)
                            .foregroundStyle(MeshTheme.textPrimary)
                            #if !os(watchOS)
                            .textFieldStyle(.roundedBorder)
                            #endif
                        Text(":")
                            .foregroundStyle(MeshTheme.textSecondary)
                        TextField("Port", text: $wifiPort)
                            .foregroundStyle(MeshTheme.textPrimary)
                            .frame(width: 60)
                            #if !os(watchOS)
                            .textFieldStyle(.roundedBorder)
                            #endif
                        Button("Connect") {
                            let port = UInt16(wifiPort) ?? 5000
                            viewModel.connectWiFi(host: wifiHost, port: port)
                            saveWiFiConnection(host: wifiHost, port: port)
                        }
                        .disabled(wifiHost.isEmpty)
                        .buttonStyle(.borderedProminent)
                        .tint(MeshTheme.interactiveGreen)
                    }
                    .listRowBackground(MeshTheme.surface)
                }
            } header: {
                Text("WiFi")
                    .foregroundStyle(MeshTheme.textSecondary)
            } footer: {
                Text("Connect to a companion radio with WiFi enabled (TCP, default port 5000).")
                    .font(.caption2)
            }

            // Diagnostic: show platform info on all platforms
            Section {
                #if os(macOS)
                let _ = DebugLogger.shared.log("SCANNER: running on macOS — USB section should show", level: .info)
                #elseif os(iOS)
                let _ = DebugLogger.shared.log("SCANNER: running on iOS — no USB section (run macOS target for USB)", level: .warning)
                #endif
                Text("Platform: \(ProcessInfo.processInfo.operatingSystemVersionString)")
                    .font(.caption2)
                    .foregroundStyle(MeshTheme.textSecondary)
                    .listRowBackground(MeshTheme.surface)
            }

            #if os(macOS)
            // USB Serial section
            Section {
                if viewModel.usbManager.isConnected {
                    HStack {
                        Image(systemName: "cable.connector")
                            .foregroundStyle(MeshTheme.connected)
                        Text(viewModel.usbManager.connectedPort?.replacingOccurrences(of: "/dev/cu.", with: "") ?? "Connected")
                            .foregroundStyle(MeshTheme.textPrimary)
                        Spacer()
                        Button("Disconnect") { viewModel.disconnectUSB() }
                            .foregroundStyle(MeshTheme.disconnected)
                    }
                    .listRowBackground(MeshTheme.surface)
                } else {
                    ForEach(viewModel.usbManager.availablePorts, id: \.self) { port in
                        HStack {
                            Image(systemName: "cable.connector")
                                .foregroundStyle(MeshTheme.accent)
                            Text(port.replacingOccurrences(of: "/dev/cu.", with: ""))
                                .foregroundStyle(MeshTheme.textPrimary)
                            Spacer()
                            Button("Connect") { viewModel.connectUSB(port: port) }
                                .buttonStyle(.borderedProminent)
                                .tint(MeshTheme.interactiveGreen)
                        }
                        .listRowBackground(MeshTheme.surface)
                    }

                    if viewModel.usbManager.availablePorts.isEmpty {
                        Text("No serial ports detected")
                            .font(.caption)
                            .foregroundStyle(MeshTheme.textSecondary)
                            .listRowBackground(MeshTheme.surface)
                    }

                    // Manual port entry
                    HStack(spacing: 8) {
                        Image(systemName: "terminal")
                            .foregroundStyle(MeshTheme.accent)
                        TextField("/dev/cu.usbmodem...", text: $manualSerialPort)
                            .font(.system(.body, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                        Button("Connect") {
                            guard !manualSerialPort.isEmpty else { return }
                            viewModel.connectUSB(port: manualSerialPort)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(MeshTheme.interactiveGreen)
                        .disabled(manualSerialPort.isEmpty)
                    }
                    .listRowBackground(MeshTheme.surface)

                    Button {
                        viewModel.usbManager.scanPorts()
                    } label: {
                        Label("Refresh Ports", systemImage: "arrow.clockwise")
                            .foregroundStyle(MeshTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(MeshTheme.surface)
                }
            } header: {
                Text("USB Serial")
                    .foregroundStyle(MeshTheme.textSecondary)
            } footer: {
                Text("Connect via USB. If not listed, run 'ls /dev/cu.*' in Terminal and enter the path manually.")
                    .font(.caption2)
            }
            .onAppear {
                viewModel.usbManager.scanPorts()
            }
            #endif
        }
        .meshListStyle()
        .navigationTitle("Scanner")
        .onAppear {
            viewModel.startScanning()
            startScanCycle()
        }
        .onDisappear {
            scanCycleTask?.cancel()
            scanCycleTask = nil
            viewModel.stopScanning()
        }
    }

    /// Runs a 15-second scan cycle. When the timer fires, tells the ViewModel
    /// to either retry (if no devices found) or keep scanning (if devices are visible).
    private func startScanCycle() {
        scanCycleTask?.cancel()
        scanCycleTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000) // 15s
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    viewModel.handleScanTimeout()
                }
            }
        }
    }

    private func signalBars(rssi: Int) -> some View {
        let strength = signalStrength(rssi: rssi)
        let color = signalColor(strength: strength)
        return HStack(spacing: 3) {
            HStack(spacing: 2) {
                ForEach(0..<4) { bar in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(bar < strength ? color : MeshTheme.surfaceLight)
                        .frame(width: 4, height: CGFloat(6 + bar * 4))
                }
            }
            Text("\(rssi) dBm")
                .font(.caption2)
                .foregroundStyle(color)
                .frame(width: 52, alignment: .trailing)
        }
    }

    private func signalStrength(rssi: Int) -> Int {
        switch rssi {
        case -65...0:        return 4  // excellent
        case -80...(-66):    return 3  // good
        case -90...(-81):    return 2  // fair
        case -100...(-91):   return 1  // weak
        default:             return 0  // no signal
        }
    }

    private func signalColor(strength: Int) -> Color {
        switch strength {
        case 4, 3:  return MeshTheme.connected
        case 2:     return .orange
        case 1:     return .red
        default:    return MeshTheme.textSecondary
        }
    }

    // MARK: - Saved WiFi Connections

    private var savedWiFiConnections: [SavedWiFiConnection] {
        (try? JSONDecoder().decode([SavedWiFiConnection].self, from: savedWiFiData)) ?? []
    }

    private func saveWiFiConnection(host: String, port: UInt16) {
        var connections = savedWiFiConnections.filter { $0.host != host || $0.port != port }
        connections.insert(SavedWiFiConnection(id: UUID(), host: host, port: port, lastConnected: Date()), at: 0)
        if connections.count > 5 { connections = Array(connections.prefix(5)) }
        if let data = try? JSONEncoder().encode(connections) {
            savedWiFiData = data
        }
    }

    private func removeWiFiConnection(_ connection: SavedWiFiConnection) {
        var connections = savedWiFiConnections
        connections.removeAll { $0.id == connection.id }
        if let data = try? JSONEncoder().encode(connections) {
            savedWiFiData = data
        }
    }
}

struct SavedWiFiConnection: Codable, Identifiable {
    let id: UUID
    let host: String
    let port: UInt16
    let lastConnected: Date
}
