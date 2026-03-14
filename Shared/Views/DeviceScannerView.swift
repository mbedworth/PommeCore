import SwiftUI
import MeshCoreKit

struct DeviceScannerView: View {
    @EnvironmentObject var viewModel: MeshCoreViewModel
    @Environment(\.dismiss) private var dismiss

    /// Tracks the scan cycle timer while the view is visible.
    @State private var scanCycleTask: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                if viewModel.discoveredPeripherals.isEmpty {
                    if viewModel.isScanning {
                        HStack(spacing: 12) {
                            ProgressView()
                                .tint(MeshTheme.accentFallback)
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
                                        .foregroundStyle(MeshTheme.accentFallback)
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
                                .tint(MeshTheme.accentFallback)
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
                                        .fill(MeshTheme.accentFallback.opacity(0.12))
                                        .frame(width: 40, height: 40)
                                    Image(systemName: "radio")
                                        .foregroundStyle(MeshTheme.accentFallback)
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
        case 4, 3:  return Color(red: 0.0, green: 0.90, blue: 0.63)  // #00E5A0 green
        case 2:     return Color.orange
        case 1:     return Color.red
        default:    return Color.gray
        }
    }
}
