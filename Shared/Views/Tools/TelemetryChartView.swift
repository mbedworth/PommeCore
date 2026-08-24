//
//  TelemetryChartView.swift
//  PommeCore
//
//  Telemetry history charts — battery, temperature, etc. over time.
//
//  Created by Michael P. Bedworth on 04/06/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

#if !os(watchOS)
import SwiftUI
import Charts
import MeshCoreKit

struct TelemetryChartView: View {
    let contactKey: Data
    let contactName: String
    @Environment(RFMonitorStore.self) private var rfStore
    @State private var selectedReading: String?

    private var availableReadings: [TelemetrySeries] {
        rfStore.availableReadings(for: contactKey)
    }

    /// Currently charted series — the user's pick, or the first available.
    private var selectedSeries: TelemetrySeries? {
        if let selectedReading, let match = availableReadings.first(where: { $0.key == selectedReading }) {
            return match
        }
        return availableReadings.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .foregroundStyle(MeshTheme.accent)
                Text("Telemetry History")
                    .font(.headline)
                    .foregroundStyle(MeshTheme.accent)
            }

            if availableReadings.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.line.downtrend.xyaxis")
                        .font(.title2)
                        .foregroundStyle(MeshTheme.textSecondary)
                    Text("No telemetry data yet")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                    Text("Request telemetry from the device to start collecting history.")
                        .font(.caption2)
                        .foregroundStyle(MeshTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else {
                // Reading type picker
                Picker("Reading", selection: Binding(
                    get: { selectedSeries?.key ?? "" },
                    set: { selectedReading = $0 }
                )) {
                    ForEach(availableReadings) { series in
                        Text(series.label).tag(series.key)
                    }
                }
                .pickerStyle(.segmented)

                let series = selectedSeries
                let readingName = series?.label ?? ""
                let data = series.map { rfStore.history(for: contactKey, series: $0) } ?? []

                if !data.isEmpty {
                    Chart(data, id: \.date) { point in
                        if data.count >= 2 {
                            LineMark(
                                x: .value("Time", point.date),
                                y: .value(readingName, point.value)
                            )
                            .foregroundStyle(MeshTheme.accent)
                            .interpolationMethod(.catmullRom)

                            AreaMark(
                                x: .value("Time", point.date),
                                y: .value(readingName, point.value)
                            )
                            .foregroundStyle(MeshTheme.accent.opacity(0.1))
                            .interpolationMethod(.catmullRom)
                        }

                        PointMark(
                            x: .value("Time", point.date),
                            y: .value(readingName, point.value)
                        )
                        .foregroundStyle(MeshTheme.accent)
                        .symbolSize(data.count == 1 ? 120 : 0)
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 5)) { value in
                            AxisValueLabel(format: .dateTime.hour().minute())
                            AxisGridLine()
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading)
                    }
                    .frame(height: 200)

                    // Latest value
                    if let latest = data.last, let series {
                        let unit = rfStore.unit(for: contactKey, series: series)
                        Text("Latest: \(String(format: "%.1f", latest.value))\(unit)")
                            .font(.caption)
                            .foregroundStyle(MeshTheme.textSecondary)
                    }

                    if data.count == 1 {
                        Text("Request telemetry again to start building history.")
                            .font(.caption2)
                            .foregroundStyle(MeshTheme.textSecondary)
                    }
                }
            }
        }
        .padding()
        .background(MeshTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
#endif
