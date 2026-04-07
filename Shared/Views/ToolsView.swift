//
//  ToolsView.swift
//  PommeCore
//
//  Planning and monitoring tools — accessible from the sidebar.
//

#if !os(watchOS)
import SwiftUI
import MeshCoreKit

struct ToolsView: View {
    @State private var showLineOfSight = false
    @State private var showNoiseFloor = false
    @State private var showRadioCalc = false
    @State private var showAirtime = false
    @State private var showSensitivity = false
    @State private var showDiscover = false

    var body: some View {
        List {
            Section {
                toolButton(
                    icon: "eye.trianglebadge.exclamationmark",
                    title: "Line of Sight",
                    subtitle: "Terrain analysis with Fresnel zone for RF path planning"
                ) {
                    showLineOfSight = true
                }

                toolButton(
                    icon: "function",
                    title: "Radio Calculator",
                    subtitle: "Link budget, path loss, wavelength, and range estimation",
                    badge: "No Radio"
                ) {
                    showRadioCalc = true
                }

                toolButton(
                    icon: "timer",
                    title: "Airtime Calculator",
                    subtitle: "LoRa time-on-air, duty cycle, and packets per hour",
                    badge: "No Radio"
                ) {
                    showAirtime = true
                }

                toolButton(
                    icon: "chart.bar",
                    title: "SF/BW Reference",
                    subtitle: "Sensitivity, bit rate, and range by spreading factor",
                    badge: "No Radio"
                ) {
                    showSensitivity = true
                }
            } header: {
                Text("Planning")
            } footer: {
                Text("These tools don't require a radio connection.")
            }

            Section {
                toolButton(
                    icon: "waveform.badge.magnifyingglass",
                    title: "RF Monitor",
                    subtitle: "Live SNR and RSSI chart from received LoRa packets"
                ) {
                    showNoiseFloor = true
                }

                toolButton(
                    icon: "magnifyingglass",
                    title: "Discover Nodes",
                    subtitle: "Scan the mesh for all reachable devices"
                ) {
                    showDiscover = true
                }
            } header: {
                Text("Monitoring")
            } footer: {
                Text("These tools require a radio connection.")
            }
        }
        .meshTheme()
        .navigationTitle("Tools")
        .sheet(isPresented: $showLineOfSight) {
            LineOfSightView()
                .frame(minWidth: 500, idealWidth: 700, minHeight: 700, idealHeight: 900)
        }
        .sheet(isPresented: $showRadioCalc) {
            NavigationStack {
                RadioCalculatorView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showRadioCalc = false }
                        }
                    }
            }
            .meshTheme()
            .frame(minWidth: 500, idealWidth: 600, minHeight: 600, idealHeight: 700)
        }
        .sheet(isPresented: $showAirtime) {
            NavigationStack {
                LoRaAirtimeView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showAirtime = false }
                        }
                    }
            }
            .meshTheme()
            .frame(minWidth: 500, idealWidth: 600, minHeight: 600, idealHeight: 700)
        }
        .sheet(isPresented: $showSensitivity) {
            NavigationStack {
                SensitivityTableView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showSensitivity = false }
                        }
                    }
            }
            .meshTheme()
            .frame(minWidth: 500, idealWidth: 600, minHeight: 600, idealHeight: 700)
        }
        .sheet(isPresented: $showNoiseFloor) {
            NavigationStack {
                ScrollView {
                    NoiseFloorMonitorView()
                        .padding()
                }
                .background(MeshTheme.background)
                .navigationTitle("RF Monitor")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showNoiseFloor = false }
                    }
                }
            }
            .meshTheme()
            .frame(minWidth: 400, minHeight: 500)
        }
        .sheet(isPresented: $showDiscover) {
            NavigationStack {
                DiscoverNodesView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showDiscover = false }
                        }
                    }
            }
            .meshTheme()
            .frame(minWidth: 400, minHeight: 400)
        }
    }

    private func toolButton(icon: String, title: String, subtitle: String, badge: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(MeshTheme.accent.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .foregroundStyle(MeshTheme.accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.body)
                            .foregroundStyle(MeshTheme.textPrimary)
                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(MeshTheme.accent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(MeshTheme.accent.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                        .lineLimit(2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(MeshTheme.surface)
    }
}
#endif
