//
//  LineOfSightView.swift
//  PommeCore
//
//  Main container for Line of Sight terrain analysis.
//  Point selection, settings, analysis trigger, results, and terrain profile.
//

#if !os(watchOS)
import SwiftUI
import MeshCoreKit

struct LineOfSightView: View {
    @Environment(LineOfSightStore.self) private var store
    @Environment(DeviceConfig.self) private var deviceConfig
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                PointSelectionView(
                    label: "Point A",
                    source: Binding(get: { store.pointASource }, set: { store.pointASource = $0 }),
                    contact: Binding(get: { store.pointAContact }, set: { store.pointAContact = $0 }),
                    mapPin: Binding(get: { store.pointAMapPin }, set: { store.pointAMapPin = $0 })
                )

                PointSelectionView(
                    label: "Point B",
                    source: Binding(get: { store.pointBSource }, set: { store.pointBSource = $0 }),
                    contact: Binding(get: { store.pointBContact }, set: { store.pointBContact = $0 }),
                    mapPin: Binding(get: { store.pointBMapPin }, set: { store.pointBMapPin = $0 })
                )

                AntennaSettingsView()
                RepeaterConfigView()

                // Analyze button
                Section {
                    if store.isAnalyzing {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Fetching terrain data...")
                                .font(.subheadline)
                                .foregroundStyle(MeshTheme.textSecondary)
                        }
                        .listRowBackground(MeshTheme.surface)
                    } else {
                        Button {
                            Task { await store.runAnalysis() }
                        } label: {
                            HStack {
                                Image(systemName: "eye.trianglebadge.exclamationmark")
                                Text("Analyze Line of Sight")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .disabled(!canAnalyze)
                        .listRowBackground(canAnalyze ? MeshTheme.interactiveGreen : MeshTheme.surfaceLight)
                        .foregroundStyle(canAnalyze ? MeshTheme.textOnAccent : MeshTheme.textSecondary)
                    }

                    if let error = store.errorMessage {
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        .listRowBackground(MeshTheme.surface)
                    }
                }

                // Results
                if let result = store.currentResult {
                    Section {
                        LoSResultsView(result: result)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }

                    Section {
                        TerrainProfileCanvas(result: result)
                            .frame(height: 280)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    } header: {
                        Text("Terrain Profile")
                    } footer: {
                        Text("Drag across the chart to inspect elevation and clearance at any point.")
                    }
                }
            }
            .meshTheme()
            .navigationTitle("Line of Sight")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                store.loadFromDeviceConfig(deviceConfig)
            }
            // Clear results when any setting changes so user can re-analyze
            .onChange(of: store.antennaHeightA) { _, _ in store.clearResults() }
            .onChange(of: store.antennaHeightB) { _, _ in store.clearResults() }
            .onChange(of: store.frequencyMHz) { _, _ in store.clearResults() }
            .onChange(of: store.repeaterEnabled) { _, _ in store.clearResults() }
            .onChange(of: store.repeaterSliderFraction) { _, _ in store.clearResults() }
            .onChange(of: store.pointASource) { _, _ in store.clearResults() }
            .onChange(of: store.pointBSource) { _, _ in store.clearResults() }
        }
    }

    private var canAnalyze: Bool {
        store.resolveCoordinates() != nil && !store.isAnalyzing
    }
}
#endif
