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
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false
    @State private var showCopiedFeedback = false

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
                            .listRowBackground(Color.clear)
                    }

                    Section {
                        TerrainProfileCanvas(result: result)
                            .frame(height: 280)
                            .frame(maxWidth: .infinity)
                            .clipped()
                            .listRowBackground(Color.clear)
                    } header: {
                        Text("Terrain Profile")
                    } footer: {
                        Text("Drag across the chart to inspect elevation and clearance at any point.")
                    }

                    Section {
                        Button {
                            renderAndShare(result: result)
                        } label: {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("Share Results")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .foregroundStyle(MeshTheme.accent)
                        .listRowBackground(MeshTheme.surface)
                    }
                }
            }
            .formStyle(.grouped)
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
            #if os(iOS)
            .sheet(isPresented: $showShareSheet) {
                if !shareItems.isEmpty {
                    ShareSheetView(activityItems: shareItems)
                }
            }
            #endif
            .overlay {
                if showCopiedFeedback {
                    Text("Copied to clipboard")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.75))
                        .clipShape(Capsule())
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut, value: showCopiedFeedback)
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 600)
        #endif
    }

    private var canAnalyze: Bool {
        store.resolveCoordinates() != nil && !store.isAnalyzing
    }

    private func renderAndShare(result: LoSResult) {
        let snapshot = LoSShareSnapshot(result: result)
        let renderer = ImageRenderer(content: snapshot.frame(width: 600))
        renderer.scale = 2
        #if os(iOS)
        if let image = renderer.uiImage {
            shareItems = [image]
            showShareSheet = true
        }
        #elseif os(macOS)
        if let image = renderer.nsImage {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
            showFeedback($showCopiedFeedback)
        }
        #endif
    }
}

/// Rendered snapshot of LoS results for sharing.
private struct LoSShareSnapshot: View {
    let result: LoSResult

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: result.overallPass ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(result.overallPass ? .green : .red)
                VStack(alignment: .leading) {
                    Text(result.overallPass ? "Line of Sight Clear" : "Line of Sight Obstructed")
                        .font(.headline)
                    Text(String(format: "%.3f km · %.1f MHz", result.profile.totalDistance / 1000, result.frequencyMHz))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Stats
            HStack(spacing: 20) {
                statItem("Min Clearance", value: String(format: "%.1f m", result.directSegment.minClearance))
                statItem("Fresnel", value: String(format: "%.0f%%", result.directSegment.fresnelClearancePercent))
                statItem("Point A", value: String(format: "%.0fm + %.0fm", result.profile.pointA.groundElevation, result.profile.pointA.antennaHeight))
                statItem("Point B", value: String(format: "%.0fm + %.0fm", result.profile.pointB.groundElevation, result.profile.pointB.antennaHeight))
            }

            // Terrain profile
            Canvas { context, size in
                TerrainProfileRenderer.draw(result: result, in: size, context: &context)
            }
            .frame(height: 250)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Footer
            Text("Generated by MeshCoreApple")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(white: 0.12))
        .foregroundStyle(.white)
    }

    private func statItem(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.medium))
        }
    }
}
#endif
