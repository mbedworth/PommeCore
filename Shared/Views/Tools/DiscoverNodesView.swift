//
//  DiscoverNodesView.swift
//  PommeCore
//
//  Standalone node discovery tool — scan for all devices on the mesh.
//  Wraps the existing discover functionality from RemoteSessionManager.
//

#if !os(watchOS)
import SwiftUI
import MeshCoreKit

struct DiscoverNodesView: View {
    @Environment(RemoteSessionManager.self) private var remoteSessionManager
    @Environment(ContactStore.self) private var contactStore
    @Environment(ConnectionManager.self) private var connectionManager

    var body: some View {
        VStack(spacing: 16) {
            if connectionManager.connectionState != .ready {
                // Not connected
                VStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.title)
                        .foregroundStyle(MeshTheme.textSecondary)
                    Text("Radio Not Connected")
                        .font(.headline)
                        .foregroundStyle(MeshTheme.textPrimary)
                    Text("Connect to a radio via BLE or WiFi to discover nodes on the mesh.")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else if remoteSessionManager.isDiscovering {
                // Discovering
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Discovering nodes...")
                        .font(.subheadline)
                        .foregroundStyle(MeshTheme.textSecondary)
                    Text("\(remoteSessionManager.discoveredNodes.count) found so far")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                }
                .padding()
            } else {
                // Results or start button
                if remoteSessionManager.discoveredNodes.isEmpty {
                    Button {
                        remoteSessionManager.startDiscover()
                    } label: {
                        HStack {
                            Image(systemName: "magnifyingglass")
                            Text("Start Discovery")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(MeshTheme.interactiveGreen)
                        .foregroundStyle(MeshTheme.textOnAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .padding()

                    if let msg = remoteSessionManager.discoverFallbackMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(MeshTheme.textSecondary)
                            .padding(.horizontal)
                    }
                } else {
                    // Node list
                    List {
                        Section {
                            ForEach(remoteSessionManager.discoveredNodes) { node in
                                HStack(spacing: 12) {
                                    Image(systemName: iconForType(node.type))
                                        .foregroundStyle(MeshTheme.accent)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(node.name.isEmpty ? "Unknown" : node.name)
                                            .font(.body)
                                            .foregroundStyle(MeshTheme.textPrimary)
                                        HStack(spacing: 8) {
                                            Text(node.type.displayName)
                                                .font(.caption2)
                                                .foregroundStyle(MeshTheme.textSecondary)
                                            if node.snr != 0 {
                                                Text("SNR: \(String(format: "%.1f", Float(node.snr) / 4.0)) dB")
                                                    .font(.caption2)
                                                    .foregroundStyle(MeshTheme.textSecondary)
                                            }
                                            if node.rssi != 0 {
                                                Text("RSSI: \(node.rssi) dBm")
                                                    .font(.caption2)
                                                    .foregroundStyle(MeshTheme.textSecondary)
                                            }
                                        }
                                    }
                                    Spacer()
                                }
                                .listRowBackground(MeshTheme.surface)
                            }
                        } header: {
                            HStack {
                                Text("\(remoteSessionManager.discoveredNodes.count) Nodes Found")
                                Spacer()
                                Button("Scan Again") {
                                    remoteSessionManager.startDiscover()
                                }
                                .font(.caption)
                            }
                        }
                    }
                    .meshTheme()
                }
            }
        }
        .navigationTitle("Discover Nodes")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func iconForType(_ type: ContactType) -> String {
        switch type {
        case .chat: return "person.fill"
        case .repeater: return "antenna.radiowaves.left.and.right"
        case .room: return "server.rack"
        case .sensor: return "sensor.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}
#endif
