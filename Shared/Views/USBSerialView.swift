#if os(macOS) || targetEnvironment(macCatalyst)
import SwiftUI
import MeshCoreKit

/// USB Serial connection section for DeviceScannerView on macOS.
struct USBSerialSection: View {
    @EnvironmentObject var viewModel: MeshCoreViewModel
    @State private var manualPort = ""

    var body: some View {
        Section {
            if viewModel.usbManager.isConnected {
                connectedRow
            } else {
                // Auto-discovered ports
                ForEach(viewModel.usbManager.availablePorts, id: \.self) { port in
                    HStack {
                        Image(systemName: "cable.connector")
                            .foregroundStyle(MeshTheme.accent)
                            .frame(width: 24)
                        Text(port.replacingOccurrences(of: "/dev/cu.", with: ""))
                            .foregroundStyle(MeshTheme.textPrimary)
                        Spacer()
                        Button("Connect") {
                            viewModel.connectUSB(port: port)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(MeshTheme.interactiveGreen)
                    }
                    .listRowBackground(MeshTheme.surface)
                }

                if viewModel.usbManager.availablePorts.isEmpty {
                    HStack {
                        Image(systemName: "cable.connector.slash")
                            .foregroundStyle(MeshTheme.textSecondary)
                        Text("No serial ports detected")
                            .font(.caption)
                            .foregroundStyle(MeshTheme.textSecondary)
                    }
                    .listRowBackground(MeshTheme.surface)
                }

                // Manual port entry fallback
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .foregroundStyle(MeshTheme.accent)
                        .frame(width: 24)
                    TextField("/dev/cu.usbmodem...", text: $manualPort)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                    Button("Connect") {
                        guard !manualPort.isEmpty else { return }
                        viewModel.connectUSB(port: manualPort)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MeshTheme.interactiveGreen)
                    .disabled(manualPort.isEmpty)
                }
                .listRowBackground(MeshTheme.surface)

                // Refresh button
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
            Text("If your device isn\u{2019}t listed, run \u{2018}ls /dev/cu.*\u{2019} in Terminal and enter the path manually. ESP32-S3 native USB may require holding BOOT during connection.")
                .font(.caption2)
        }
        .onAppear {
            DebugLogger.shared.log("USB SECTION: rendered on macOS, scanning ports...", level: .info)
            viewModel.usbManager.scanPorts()
        }
    }

    private var connectedRow: some View {
        HStack {
            Image(systemName: "cable.connector")
                .foregroundStyle(MeshTheme.connected)
                .frame(width: 24)
            VStack(alignment: .leading) {
                Text(viewModel.usbManager.connectedPort?.replacingOccurrences(of: "/dev/cu.", with: "") ?? "Connected")
                    .foregroundStyle(MeshTheme.textPrimary)
                Text(modeLabel)
                    .font(.caption)
                    .foregroundStyle(MeshTheme.textSecondary)
            }
            Spacer()
            Button("Disconnect") {
                viewModel.disconnectUSB()
            }
            .foregroundStyle(MeshTheme.disconnected)
        }
        .listRowBackground(MeshTheme.surface)
    }

    private var modeLabel: String {
        switch viewModel.usbManager.detectedMode {
        case .unknown: return "Detecting..."
        case .binary: return "Companion (binary protocol)"
        case .cli: return "CLI mode (repeater/room server)"
        }
    }
}

// MARK: - USB Terminal View (CLI Mode)

struct USBTerminalView: View {
    @EnvironmentObject var viewModel: MeshCoreViewModel
    @State private var commandText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Output log
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(viewModel.usbCLIOutput) { line in
                            Text(line.text)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(line.isCommand ? MeshTheme.accent : MeshTheme.textPrimary)
                                .textSelection(.enabled)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: viewModel.usbCLIOutput.count) { _ in
                    if let last = viewModel.usbCLIOutput.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Command input
            HStack(spacing: 8) {
                Text(">")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(MeshTheme.accent)
                TextField("Enter command...", text: $commandText)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.plain)
                    .onSubmit {
                        guard !commandText.isEmpty else { return }
                        viewModel.sendUSBCLI(commandText)
                        commandText = ""
                    }
                Button {
                    guard !commandText.isEmpty else { return }
                    viewModel.sendUSBCLI(commandText)
                    commandText = ""
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(MeshTheme.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(MeshTheme.surface)
        }
        .background(MeshTheme.background)
        .navigationTitle("USB Terminal")
    }
}
#endif
