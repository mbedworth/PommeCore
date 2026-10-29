//
//  USBSerialView.swift
//  PommeCore
//
//  Terminal view for raw CLI interaction with a radio.
//
//  Was macOS-only, because the only CLI transport was USB serial and
//  `USBSerialManager` needs IOKit. Firmware 1.18.0 added `CMD_RUN_CLI_COMMAND`,
//  which carries the same CLI over the binary link — so this works on iOS now,
//  against the radio in your hand.
//
//  Created by Michael P. Bedworth on 3/16/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import SwiftUI
import MeshCoreKit

// MARK: - CLI Terminal View

struct CLITerminalView: View {
    @Environment(RemoteSessionManager.self) private var remoteSessionManager
    @Environment(ConnectionManager.self) private var connectionManager
    @State private var commandText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Output log
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(remoteSessionManager.cliOutput) { line in
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
                .onChange(of: remoteSessionManager.cliOutput.count) {
                    if let last = remoteSessionManager.cliOutput.last {
                        withMeshAnimation(.easeOut(duration: 0.2)) {
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
                        sendCommand()
                    }
                Button {
                    guard !commandText.isEmpty else { return }
                    sendCommand()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .accessibilityLabel("Send command")
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
        .navigationTitle("Radio Terminal")
    }

    /// Route to whichever CLI transport is live.
    ///
    /// The companion path is preferred when the radio supports it: it is
    /// request/response, so it is serialised by the reply rather than by the
    /// USB queue's 500ms guess, and it echoes its own command into the
    /// transcript. The USB branch keeps appending here because its send is
    /// fire-and-forget.
    private func sendCommand() {
        let command = commandText
        commandText = ""
        if remoteSessionManager.companionCLISupported == true {
            Task { @MainActor in
                await remoteSessionManager.runCompanionCLI(command)
            }
            return
        }
        #if os(macOS) || targetEnvironment(macCatalyst)
        connectionManager.sendUSBCLI(command)
        remoteSessionManager.cliOutput.append(CLITerminalLine(text: "> \(command)", isCommand: true))
        #endif
    }
}
