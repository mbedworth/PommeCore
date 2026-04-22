//
//  NoiseFloorMonitorView.swift
//  PommeCore
//
//  Live RF noise floor chart showing SNR and RSSI from LOG_RX_DATA (0x88).
//
//  Created by Michael P. Bedworth on 04/06/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

#if !os(watchOS)
import SwiftUI
import Charts

struct NoiseFloorMonitorView: View {
    @Environment(RFMonitorStore.self) private var rfStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header + toggle
            HStack {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .foregroundStyle(MeshTheme.accent)
                Text("RF Monitor")
                    .font(.headline)
                    .foregroundStyle(MeshTheme.accent)
                Spacer()
                Button {
                    rfStore.toggleMonitoring()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: rfStore.isMonitoring ? "stop.circle.fill" : "play.circle.fill")
                        Text(rfStore.isMonitoring ? "Stop" : "Start")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(rfStore.isMonitoring ? .red : MeshTheme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(rfStore.isMonitoring ? Color.red.opacity(0.1) : MeshTheme.surfaceLight)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            if rfStore.isMonitoring && rfStore.rfSamples.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Listening for LoRa packets...")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else if !rfStore.rfSamples.isEmpty {
                // SNR chart
                VStack(alignment: .leading, spacing: 4) {
                    Text("SNR (dB)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(MeshTheme.textSecondary)
                    Chart(rfStore.rfSamples) { sample in
                        LineMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("SNR", sample.snr)
                        )
                        .foregroundStyle(.green)
                        .interpolationMethod(.catmullRom)
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                            AxisValueLabel(format: .dateTime.hour().minute().second())
                            AxisGridLine()
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading)
                    }
                    .frame(height: 120)
                }

                // RSSI chart
                VStack(alignment: .leading, spacing: 4) {
                    Text("RSSI (dBm)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(MeshTheme.textSecondary)
                    Chart(rfStore.rfSamples) { sample in
                        LineMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("RSSI", Int(sample.rssi))
                        )
                        .foregroundStyle(.orange)
                        .interpolationMethod(.catmullRom)
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                            AxisValueLabel(format: .dateTime.hour().minute().second())
                            AxisGridLine()
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading)
                    }
                    .frame(height: 120)
                }

                // Stats
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    statCard("Avg SNR", value: rfStore.averageSNR.map { String(format: "%.1f dB", $0) } ?? "--")
                    statCard("Peak SNR", value: rfStore.peakSNR.map { String(format: "%.1f dB", $0) } ?? "--")
                    statCard("Avg RSSI", value: rfStore.averageRSSI.map { String(format: "%.0f dBm", $0) } ?? "--")
                    statCard("Packets", value: "\(rfStore.rfSamples.count)")
                }
            } else {
                Text("Tap Start to begin capturing LoRa packet signal data.")
                    .font(.caption)
                    .foregroundStyle(MeshTheme.textSecondary)
            }
        }
        .padding()
        .background(MeshTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func statCard(_ label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(MeshTheme.textSecondary)
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(MeshTheme.textSecondary)
        }
    }
}
#endif
