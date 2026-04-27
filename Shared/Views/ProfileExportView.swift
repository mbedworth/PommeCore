//
//  ProfileExportView.swift
//  PommeCore
//
//  Export and import .meshprofile configuration files.
//  Export: radio params + channels. Private key is never included (serial-only).
//  Import: applies settings to the currently connected radio, then prompts reboot.
//

import SwiftUI
import MeshCoreKit
import UniformTypeIdentifiers

#if !os(watchOS)
struct ProfileExportView: View {
    @Environment(ConnectionManager.self) private var connectionManager
    @Environment(ChannelStore.self) private var channelStore
    @Environment(DeviceConfig.self) private var deviceConfig
    @Environment(\.dismiss) private var dismiss

    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var showExportShare = false

    @State private var importedProfile: MeshProfileExport?
    @State private var showFilePicker = false
    @State private var importError: String?
    @State private var isApplying = false
    @State private var applyDone = false

    private var isConnected: Bool {
        connectionManager.isActivelyConnected
    }

    var body: some View {
        List {
            exportSection
            importSection
        }
        .navigationTitle("Backup & Transfer")
        .meshListStyle()
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: [.data],
                      onCompletion: handleImportPick)
        .sheet(isPresented: $showExportShare) {
            if let url = exportURL {
                ShareSheet(items: [url])
            }
        }
    }

    // MARK: - Export

    private var exportSection: some View {
        Section {
            if isConnected {
                Button {
                    buildAndShareExport()
                } label: {
                    HStack {
                        Label("Export Config", systemImage: "square.and.arrow.up")
                            .foregroundStyle(MeshTheme.accent)
                        Spacer()
                        if let err = exportError {
                            Text(err).font(.caption).foregroundStyle(.red)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(MeshTheme.textSecondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(MeshTheme.surface)
            } else {
                LabelValueRow(label: "Export Config", value: "Connect to radio first")
                    .listRowBackground(MeshTheme.surface)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Exports radio name, frequency, spreading factor, bandwidth, TX power, channels, and access settings.")
                    .font(.caption)
                    .foregroundStyle(MeshTheme.textSecondary)
                HStack(spacing: 4) {
                    Image(systemName: "key.slash")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("Radio identity (private key) is not included. Use Settings → Device → Identity Backup while connected via USB.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .listRowBackground(MeshTheme.surface)
        } header: {
            SectionInfoHeader(title: "Export", info: "Save your radio's configuration to a .meshprofile file. Share it to clone settings to another radio or keep as a backup.")
        }
    }

    // MARK: - Import

    private var importSection: some View {
        Section {
            Button {
                importError = nil
                showFilePicker = true
            } label: {
                Label("Choose .meshprofile File", systemImage: "square.and.arrow.down")
                    .foregroundStyle(MeshTheme.accent)
            }
            .buttonStyle(.plain)
            .listRowBackground(MeshTheme.surface)

            if let err = importError {
                Text(err).font(.caption).foregroundStyle(.red)
                    .listRowBackground(MeshTheme.surface)
            }

            if let profile = importedProfile {
                importPreview(profile)
            }
        } header: {
            SectionInfoHeader(title: "Import", info: "Apply a .meshprofile to the connected radio. All matching settings will be overwritten. A reboot is required after import.")
        }
    }

    @ViewBuilder
    private func importPreview(_ profile: MeshProfileExport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview").font(.caption).foregroundStyle(MeshTheme.textSecondary)
            previewRow("Name", value: profile.radio.deviceName)
            previewRow("Frequency", value: String(format: "%.3f MHz",
                                                   Double(profile.radio.radioFrequency) / 1000.0))
            previewRow("SF / BW", value: "SF\(profile.radio.radioSpreadingFactor) / \(profile.radio.radioBandwidth / 1000) kHz")
            previewRow("Channels", value: "\(profile.channels.filter { $0.index > 0 }.count) private")
            if profile.privateKeyHex != nil {
                HStack(spacing: 4) {
                    Image(systemName: "key.fill").font(.caption).foregroundStyle(.green)
                    Text("Identity key included").font(.caption).foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(MeshTheme.surface)

        if !isConnected {
            Text("Connect to a radio to apply this profile.")
                .font(.caption).foregroundStyle(.orange)
                .listRowBackground(MeshTheme.surface)
        } else if applyDone {
            Label("Applied — reboot your radio to activate.", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
                .listRowBackground(MeshTheme.surface)
        } else {
            Button {
                Task { await applyImport(profile) }
            } label: {
                HStack {
                    Label(isApplying ? "Applying…" : "Apply Profile",
                          systemImage: isApplying ? "hourglass" : "checkmark.circle")
                        .foregroundStyle(isApplying ? MeshTheme.textSecondary : MeshTheme.accent)
                    Spacer()
                    if isApplying { ProgressView().tint(MeshTheme.accent) }
                }
            }
            .buttonStyle(.plain)
            .disabled(isApplying)
            .listRowBackground(MeshTheme.surface)
        }
    }

    private func previewRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(MeshTheme.accent).font(.subheadline)
            Spacer()
            Text(value).foregroundStyle(MeshTheme.textPrimary).font(.subheadline)
        }
    }

    // MARK: - Actions

    private func buildAndShareExport() {
        exportError = nil
        do {
            let profile = ProfileExportService.buildExport(
                deviceConfig: deviceConfig,
                channelStore: channelStore,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
            exportURL = try ProfileExportService.exportURL(
                from: profile, radioName: deviceConfig.advertName)
            showExportShare = true
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func handleImportPick(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                importedProfile = try ProfileExportService.parseImport(from: url)
                importError = nil
                applyDone = false
            } catch {
                importError = "Could not read file: \(error.localizedDescription)"
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func applyImport(_ profile: MeshProfileExport) async {
        isApplying = true
        await ProfileExportService.applyProfile(profile,
                                                connectionManager: connectionManager,
                                                channelStore: channelStore)
        isApplying = false
        applyDone = true
    }
}

// MARK: - ShareSheet (iOS/macOS)

private struct ShareSheet: View {
    let items: [Any]

    var body: some View {
        #if os(macOS) || targetEnvironment(macCatalyst)
        Text("Use the share menu to save or send the file.")
            .padding()
            .onAppear { openShareSheet() }
        #else
        ShareSheetRepresentable(items: items)
        #endif
    }

    #if os(macOS) || targetEnvironment(macCatalyst)
    private func openShareSheet() {
        // macOS: use NSSharingServicePicker — not available in pure SwiftUI; caller uses ShareLink
    }
    #else
    private struct ShareSheetRepresentable: UIViewControllerRepresentable {
        let items: [Any]
        func makeUIViewController(context: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: items, applicationActivities: nil)
        }
        func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
    }
    #endif
}
#endif
