//
//  FirmwareUpdateView.swift
//  PommeCore
//
//  Step-by-step guided UI for ESP32 WiFi OTA firmware updates.
//

import SwiftUI
import MeshCoreKit

#if !os(watchOS)
struct FirmwareUpdateView: View {
    @Environment(ConnectionManager.self) private var connectionManager
    @Environment(DeviceConfig.self) private var deviceConfig
    @Environment(\.dismiss) private var dismiss
    let latestVersion: String

    @State private var otaService = FirmwareOTAService()

    var body: some View {
        NavigationStack {
            ZStack {
                MeshTheme.background.ignoresSafeArea()
                stepContent
                    .padding()
            }
            .navigationTitle("Firmware Update")
            #if os(macOS) || targetEnvironment(macCatalyst)
            .navigationSubtitle("v\(latestVersion)")
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .meshTheme()
        #if os(macOS) || targetEnvironment(macCatalyst)
        .frame(minWidth: 480, minHeight: 400)
        #endif
        .task { await otaService.start(manufacturer: deviceConfig.manufacturer) }
        .interactiveDismissDisabled(isActiveStep)
    }

    // Prevent accidental dismissal during download/upload
    private var isActiveStep: Bool {
        switch otaService.step {
        case .downloading, .uploading: return true
        default: return false
        }
    }

    // MARK: - Step Router

    @ViewBuilder
    private var stepContent: some View {
        switch otaService.step {
        case .ready, .fetchingAssets:
            loadingView("Loading firmware list...")

        case .selectingFirmware(let assets, let suggested):
            selectionView(assets: assets, suggested: suggested)

        case .downloading(let progress, let asset):
            downloadingView(progress: progress, asset: asset)

        case .activateOTA(let data, let asset):
            activateView(firmwareData: data, asset: asset)

        case .detectingRadio(_, _):
            detectingView

        case .uploading(let progress):
            uploadingView(progress: progress)

        case .done:
            doneView

        case .failed(let message, let canRetry):
            failedView(message: message, canRetry: canRetry)
        }
    }

    // MARK: - Loading

    private func loadingView(_ message: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(MeshTheme.accent)
            Text(message)
                .foregroundStyle(MeshTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Selection

    private func selectionView(assets: [OTAAsset], suggested: OTAAsset?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            stepHeader(
                icon: "cpu",
                title: "Select Your Hardware",
                subtitle: "Choose the firmware binary that matches your radio board."
            )

            if let match = suggested {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Detected")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MeshTheme.accent)
                    assetRow(match, badge: "Suggested") {
                        Task { await otaService.selectAsset(match) }
                    }
                }
                .padding(.bottom, 16)

                Text("All boards")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MeshTheme.textSecondary)
                    .padding(.bottom, 4)
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(assets) { asset in
                        assetRow(asset, badge: nil) {
                            Task { await otaService.selectAsset(asset) }
                        }
                    }
                }
            }
        }
    }

    private func assetRow(_ asset: OTAAsset, badge: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "memorychip")
                    .font(.title3)
                    .foregroundStyle(MeshTheme.accent)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(asset.displayName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(MeshTheme.textPrimary)
                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(MeshTheme.accent.opacity(0.15))
                                .foregroundStyle(MeshTheme.accent)
                                .clipShape(Capsule())
                        }
                    }
                    Text(asset.sizeFormatted)
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(MeshTheme.textSecondary)
            }
            .padding(12)
            .background(MeshTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Downloading

    private func downloadingView(progress: Double, asset: OTAAsset) -> some View {
        VStack(spacing: 24) {
            stepHeader(
                icon: "arrow.down.circle",
                title: "Downloading Firmware",
                subtitle: "Downloading \(asset.displayName) — \(asset.sizeFormatted)"
            )

            VStack(spacing: 8) {
                ProgressView(value: progress > 0 ? progress : nil)
                    .tint(MeshTheme.accent)
                if progress > 0 {
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                }
            }

            Text("Keep the app open while downloading.")
                .font(.caption)
                .foregroundStyle(MeshTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Activate OTA

    private func activateView(firmwareData: Data, asset: OTAAsset) -> some View {
        VStack(spacing: 24) {
            stepHeader(
                icon: "wifi",
                title: "Activate OTA Mode",
                subtitle: "Your radio needs to create a WiFi hotspot for the update."
            )

            VStack(alignment: .leading, spacing: 12) {
                // Step A: trigger OTA mode
                instructionCard(number: "1", title: "Start OTA mode on your radio") {
                    VStack(alignment: .leading, spacing: 8) {
                        #if os(macOS) || targetEnvironment(macCatalyst)
                        if connectionManager.isUSBCLIMode {
                            Text("Your radio is connected via USB CLI. Tap the button below to send the command.")
                                .font(.subheadline)
                                .foregroundStyle(MeshTheme.textPrimary)
                            Button {
                                connectionManager.sendUSBCLI("start ota")
                            } label: {
                                Label("Send start ota Command", systemImage: "terminal")
                                    .foregroundStyle(MeshTheme.accent)
                            }
                            .buttonStyle(.plain)
                        } else {
                            otaManualInstructions
                        }
                        #else
                        otaManualInstructions
                        #endif
                    }
                }

                // Step B: connect to WiFi
                instructionCard(number: "2", title: "Connect to '\(FirmwareOTAService.otaSSID)' WiFi") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("After the radio starts OTA mode, go to your device Settings → Wi-Fi and connect to:")
                            .font(.subheadline)
                            .foregroundStyle(MeshTheme.textPrimary)
                        HStack(spacing: 8) {
                            Image(systemName: "wifi")
                                .foregroundStyle(MeshTheme.accent)
                            Text(FirmwareOTAService.otaSSID)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(MeshTheme.textPrimary)
                        }
                        Text("No password required. Then return to this screen.")
                            .font(.caption)
                            .foregroundStyle(MeshTheme.textSecondary)
                    }
                }
            }

            Button {
                otaService.beginDetection(firmwareData: firmwareData, asset: asset)
            } label: {
                Text("I've Connected — Continue")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(MeshTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Detecting Radio

    private var detectingView: some View {
        VStack(spacing: 24) {
            stepHeader(
                icon: "magnifyingglass",
                title: "Looking for Radio",
                subtitle: "Waiting for 192.168.4.1 to become reachable…"
            )

            ProgressView()
                .controlSize(.large)
                .tint(MeshTheme.accent)

            VStack(spacing: 4) {
                Text("Make sure your device is connected to '\(FirmwareOTAService.otaSSID)' WiFi.")
                    .font(.subheadline)
                    .foregroundStyle(MeshTheme.textSecondary)
                    .multilineTextAlignment(.center)
                Text("This may take up to 30 seconds after the radio starts OTA mode.")
                    .font(.caption)
                    .foregroundStyle(MeshTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Uploading

    private func uploadingView(progress: Double) -> some View {
        VStack(spacing: 24) {
            stepHeader(
                icon: "arrow.up.circle",
                title: "Uploading Firmware",
                subtitle: "Transferring firmware to your radio over WiFi…"
            )

            VStack(spacing: 8) {
                ProgressView(value: progress > 0 ? progress : nil)
                    .tint(MeshTheme.accent)
                if progress > 0 {
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                }
            }

            Text("Do not close the app or disconnect from '\(FirmwareOTAService.otaSSID)' WiFi.")
                .font(.caption)
                .foregroundStyle(MeshTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Done

    private var doneView: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)

            VStack(spacing: 8) {
                Text("Firmware Updated!")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(MeshTheme.textPrimary)
                Text("Your radio is flashing the new firmware and will restart. Reconnect your device's WiFi to your normal network, then the app will reconnect to the radio.")
                    .font(.subheadline)
                    .foregroundStyle(MeshTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(MeshTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Failed

    private func failedView(message: String, canRetry: Bool) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.orange)

            VStack(spacing: 8) {
                Text("Update Failed")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(MeshTheme.textPrimary)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(MeshTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            if canRetry {
                Button {
                    Task { await otaService.start(manufacturer: deviceConfig.manufacturer) }
                } label: {
                    Text("Try Again")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(MeshTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }

            Button { dismiss() } label: {
                Text("Close")
                    .foregroundStyle(MeshTheme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var otaManualInstructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect your radio via USB serial and run:")
                .font(.subheadline)
                .foregroundStyle(MeshTheme.textPrimary)
            Text("start ota")
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(MeshTheme.accent.opacity(0.1))
                .foregroundStyle(MeshTheme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text("Alternatively, use the physical OTA button if your hardware has one.")
                .font(.caption)
                .foregroundStyle(MeshTheme.textSecondary)
        }
    }

    // MARK: - Reusable layout pieces

    private func stepHeader(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(MeshTheme.accent)
            VStack(spacing: 4) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(MeshTheme.textPrimary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(MeshTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.bottom, 8)
    }

    private func instructionCard(number: String, title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(number)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(width: 20, height: 20)
                    .background(MeshTheme.accent)
                    .clipShape(Circle())
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MeshTheme.textPrimary)
            }
            content()
                .padding(.leading, 28)
        }
        .padding(14)
        .background(MeshTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
#endif
