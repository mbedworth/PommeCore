//
//  NodeSetupWizardView.swift
//  MeshCoreApple
//
//  Node Setup Wizard — directs users to the namer website to generate a
//  standardized node name, then lets them paste it and apply.
//
//  Created by Michael P. Bedworth on 4/1/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import SwiftUI
import MeshCoreKit

/// Context for running the wizard against a remote device via CLI.
struct RemoteWizardContext {
    let contact: Contact
    let publicKeyHex: String
    let sendCLI: (String) -> Void
    /// Current device name from session settings, used to skip no-op set name.
    var currentName: String?
    /// Called after a name is successfully sent, so the session stays in sync.
    var onNameApplied: ((String) -> Void)?
    /// Current radio frequency in kHz, if known from session settings.
    var currentFrequencyKHz: Double?
}

struct NodeSetupWizardView: View {
    @Environment(\.dismiss) private var dismiss
    #if !os(watchOS)
    @Environment(\.openURL) private var openURL
    #endif

    /// When set, the wizard targets a remote device via CLI instead of the local connection.
    var remoteContext: RemoteWizardContext?

    /// Key prefix passed in to avoid @Environment(DeviceConfig) which can cause
    /// USB disconnects on Catalyst when the sheet dismisses.
    var publicKeyHex: String = ""

    private var isRemote: Bool { remoteContext != nil }

    @State private var nodeName: String = ""
    @State private var nameApplied = false
    @State private var showRebootPrompt = false

    private var keyPrefix: String {
        let hex = remoteContext?.publicKeyHex ?? publicKeyHex
        return hex.count >= 5 ? String(hex.prefix(5)) : ""
    }

    private var namerURL: URL? {
        var components = URLComponents(string: "https://namer.mnbsyr.com")
        if !keyPrefix.isEmpty {
            components?.queryItems = [URLQueryItem(name: "key", value: keyPrefix)]
        }
        return components?.url
    }

    private var nameBytes: Int {
        nodeName.utf8.count
    }

    private var isNameValid: Bool {
        !nodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && nameBytes <= 24
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "tag.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(MeshTheme.accent)
                    Text("Name Your Node")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Use the MeshCore Node Namer to generate a standardized name for your device.")
                        .font(.subheadline)
                        .foregroundStyle(MeshTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 8)

                // Key prefix display
                if !keyPrefix.isEmpty {
                    VStack(spacing: 4) {
                        Text("Your Key Prefix")
                            .font(.caption)
                            .foregroundStyle(MeshTheme.textSecondary)
                        HStack(spacing: 8) {
                            Text(keyPrefix)
                                .font(.system(.title3, design: .monospaced))
                                .fontWeight(.bold)
                                .foregroundStyle(MeshTheme.accent)
                            CopyButton(text: keyPrefix, label: "Copy", icon: "doc.on.doc")
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(MeshTheme.surface)
                    )
                }

                // Open website button
                #if !os(watchOS)
                Button {
                    if let url = namerURL { openURL(url) }
                } label: {
                    HStack {
                        Image(systemName: "safari")
                        Text("Open Node Namer")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(MeshTheme.accent)
                    .foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                #endif

                if isRemote {
                    // Paste name field — remote devices only
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Paste your generated name:")
                            .font(.subheadline)
                            .foregroundStyle(MeshTheme.textSecondary)

                        TextField("e.g. US-NC-RDU-CR-f9ac5", text: $nodeName)
                            .textFieldStyle(.roundedBorder)
                            #if os(iOS)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            #endif
                            .onChange(of: nodeName) { _, newValue in
                                // Trim to last 24 UTF-8 bytes to prevent overflow
                                // and keep the most recently typed characters.
                                if newValue.utf8.count > 24 {
                                    var trimmed = newValue
                                    while trimmed.utf8.count > 24 {
                                        trimmed.removeFirst()
                                    }
                                    nodeName = trimmed
                                }
                            }

                        if !nodeName.isEmpty {
                            HStack {
                                Text("\(nameBytes) / \(24) bytes")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Spacer()
                                if nameBytes <= 24 {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                } else {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.red)
                                }
                            }
                            .foregroundStyle(nameBytes <= 24 ? MeshTheme.textSecondary : .red)
                        }
                    }

                    // Apply button
                    Button {
                        applyName()
                    } label: {
                        HStack {
                            Image(systemName: nameApplied ? "checkmark.circle.fill" : "arrow.right.circle.fill")
                            Text(nameApplied ? "Name Applied" : "Apply Name")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(nameApplied ? Color.green.opacity(0.2) : MeshTheme.accent)
                        .foregroundStyle(nameApplied ? .green : .black)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(!isNameValid || nameApplied)
                } else {
                    Text("Copy your key prefix, generate a name on the website, then paste it into the Name field in Settings.")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
        }
        .background(MeshTheme.background)
        .alert("Name Updated", isPresented: $showRebootPrompt) {
            Button("OK") { dismiss() }
        } message: {
            Text("The device name has been updated. Now set your radio preset in Settings \u{2192} Radio to match your region. Then press the physical reset button on your radio, wait for it to reboot, and unplug and replug the USB cable.")
        }
    }

    private func applyName() {
        guard let remote = remoteContext else { return }
        let name = nodeName.trimmingCharacters(in: .whitespacesAndNewlines)

        // Skip set name if unchanged — firmware doesn't respond, which stalls the CLI queue.
        if remote.currentName?.lowercased() != name.lowercased() {
            remote.sendCLI("set name \(name)")
            remote.onNameApplied?(name)
            withAnimation { nameApplied = true }
            showRebootPrompt = true
        } else {
            withAnimation { nameApplied = true }
            dismiss()
        }
    }
}
