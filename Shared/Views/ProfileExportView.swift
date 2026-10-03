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
    @Environment(ContactStore.self) private var contactStore
    @Environment(\.dismiss) private var dismiss

    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var showExportShare = false
    /// Off by default — see the toggle in `exportSection`.
    @State private var includeContacts = false

    @State private var importedProfile: MeshProfileExport?
    @State private var showFilePicker = false
    @State private var importError: String?
    @State private var isApplying = false
    @State private var applyDone = false
    /// Set when the link dropped part-way through, so the radio is
    /// part-configured and the user needs to know.
    @State private var applyInterruptedAt: String?
    /// Off by default: a file may carry contacts the user does not want on
    /// this radio.
    @State private var applyContacts = false

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
        #if !os(macOS)
        .sheet(isPresented: $showExportShare) {
            if let url = exportURL {
                ShareSheet(items: [url])
            }
        }
        #endif
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

            // Off by default, and says why when switched on. The export screen
            // invites sharing the file, and a contact list is the user's
            // social graph — that has to be a decision, not a default.
            Toggle(isOn: $includeContacts) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include Contacts")
                        .foregroundStyle(MeshTheme.accent)
                    Text(contactStore.contacts.isEmpty
                         ? String(localized: "No contacts to include")
                         : String(format: String(localized: "Adds %d contacts so another radio can be set up with the same mesh"),
                                  contactStore.contacts.count))
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                }
            }
            .disabled(contactStore.contacts.isEmpty)
            .listRowBackground(MeshTheme.surface)

            if includeContacts && !contactStore.contacts.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("This file will contain contact names, public keys and any positions they advertise. Don\u{2019}t share it with anyone you wouldn\u{2019}t share your contact list with.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
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
                    Text("Radio identity (private key) is not included. To back up your radio's identity, use the PommeCore Mac app: Settings → Device → Identity Backup while connected via USB.")
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
            if let contacts = profile.contacts {
                previewRow("Contacts", value: "\(contacts.count)")
            }
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
        } else if let step = applyInterruptedAt {
            // Never report success for a partial apply: the settings are
            // idempotent, so importing again fixes it — but only if the user
            // knows it did not finish.
            Label("Connection lost while applying \(step). The radio is part-configured \u{2014} reconnect and apply again.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
                .listRowBackground(MeshTheme.surface)
        } else if applyDone {
            Label("Applied — reboot your radio to activate.", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
                .listRowBackground(MeshTheme.surface)
        } else {
            if let contacts = profile.contacts, !contacts.isEmpty {
                Toggle(isOn: $applyContacts) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add Contacts")
                            .foregroundStyle(MeshTheme.accent)
                        Text(String(format: String(localized: "Adds the %d contacts in this file to your radio. Existing contacts are updated, never removed."),
                                    contacts.count))
                            .font(.caption)
                            .foregroundStyle(MeshTheme.textSecondary)
                    }
                }
                .listRowBackground(MeshTheme.surface)
            }

            Button {
                Task { await applyImport(profile) }
            } label: {
                HStack {
                    (isApplying ? Label("Applying…", systemImage: "hourglass") : Label("Apply Profile", systemImage: "checkmark.circle"))
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

    private func previewRow(_ label: LocalizedStringKey, value: String) -> some View {
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
                contacts: includeContacts ? contactStore.contacts : nil,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
            let url = try ProfileExportService.exportURL(
                from: profile, radioName: deviceConfig.deviceName)
            exportURL = url
            #if os(macOS)
            presentSavePanel(for: url)
            #else
            showExportShare = true
            #endif
        } catch {
            exportError = error.localizedDescription
        }
    }

    #if os(macOS)
    /// Run the save panel directly from the action, not from inside a sheet.
    ///
    /// It used to be presented inside a `.sheet` holding a 1×1 `Color.clear`,
    /// which left an empty rounded rectangle on screen and no save panel at
    /// all: the sheet window stays key, so the panel never comes forward, and
    /// there is nothing in the sheet to dismiss it with. Exporting was
    /// effectively impossible on macOS.
    private func presentSavePanel(for url: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.allowedContentTypes = [.data]

        let complete: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                // The panel already asked about replacing, so an existing file
                // here means the user said yes. `copyItem` throws onto an
                // existing path, and that used to be swallowed by `try?` — the
                // panel closed, nothing was written, and the export looked
                // like it had succeeded.
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: url, to: destination)
            } catch {
                exportError = error.localizedDescription
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: complete)
        } else {
            panel.begin(completionHandler: complete)
        }
    }
    #endif

    private func handleImportPick(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                importedProfile = try ProfileExportService.parseImport(from: url)
                importError = nil
                applyDone = false
                applyInterruptedAt = nil
            } catch {
                importError = "Could not read file: \(error.localizedDescription)"
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func applyImport(_ profile: MeshProfileExport) async {
        isApplying = true
        let outcome = await ProfileExportService.applyProfile(profile,
                                                connectionManager: connectionManager,
                                                channelStore: channelStore,
                                                contactStore: contactStore,
                                                applyContacts: applyContacts)
        isApplying = false
        switch outcome {
        case .applied:
            applyInterruptedAt = nil
            applyDone = true
        case .interrupted(let step):
            applyInterruptedAt = step
            applyDone = false
        }
    }
}

// MARK: - ShareSheet (iOS/macOS)

// iOS only. macOS runs NSSavePanel directly from the export action — see
// `presentSavePanel(for:)`, and the comment there for why it cannot live
// inside a sheet.
#if !os(macOS)
private struct ShareSheet: View {
    let items: [Any]

    var body: some View {
        ShareSheetRepresentable(items: items)
    }

    private struct ShareSheetRepresentable: UIViewControllerRepresentable {
        let items: [Any]
        func makeUIViewController(context: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: items, applicationActivities: nil)
        }
        func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
    }
}
#endif
#endif
