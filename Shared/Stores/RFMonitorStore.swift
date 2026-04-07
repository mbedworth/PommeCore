//
//  RFMonitorStore.swift
//  PommeCore
//
//  Stores telemetry history and noise floor (SNR/RSSI) readings for charts.
//

import Foundation
import MeshCoreKit

/// A timestamped telemetry snapshot for history charts.
struct TelemetrySnapshot: Identifiable {
    let id = UUID()
    let timestamp: Date
    let readings: [TelemetryReading]

    func value(named name: String) -> Double? {
        readings.first(where: { $0.name == name })?.value
    }
}

/// A single SNR/RSSI sample from LOG_RX_DATA (0x88).
struct RFSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let snr: Double   // dB (raw / 4.0)
    let rssi: Int8    // dBm
}

@MainActor @Observable
final class RFMonitorStore {

    // MARK: - Telemetry History

    /// Telemetry history per contact (keyed by publicKeyPrefix).
    /// Stores up to maxHistoryCount snapshots per contact.
    var telemetryHistory: [Data: [TelemetrySnapshot]] = [:]

    private let maxHistoryCount = 100

    /// Record a new telemetry reading for a contact.
    func recordTelemetry(for contactKey: Data, readings: [TelemetryReading]) {
        let snapshot = TelemetrySnapshot(timestamp: Date(), readings: readings)
        var history = telemetryHistory[contactKey] ?? []
        history.append(snapshot)
        if history.count > maxHistoryCount {
            history.removeFirst(history.count - maxHistoryCount)
        }
        telemetryHistory[contactKey] = history
    }

    /// Get history for a specific reading type (e.g. "Battery", "Temperature").
    func history(for contactKey: Data, named name: String) -> [(date: Date, value: Double)] {
        guard let snapshots = telemetryHistory[contactKey] else { return [] }
        return snapshots.compactMap { snapshot in
            guard let value = snapshot.value(named: name) else { return nil }
            return (snapshot.timestamp, value)
        }
    }

    /// Available reading names for a contact's history.
    func availableReadings(for contactKey: Data) -> [String] {
        guard let snapshots = telemetryHistory[contactKey],
              let latest = snapshots.last else { return [] }
        return latest.readings.map(\.name)
    }

    // MARK: - Noise Floor (RF Monitor)

    /// Rolling buffer of SNR/RSSI samples from 0x88 LOG_RX_DATA.
    var rfSamples: [RFSample] = []

    /// Whether RF monitoring is actively capturing.
    var isMonitoring = false

    private let maxRFSamples = 300  // ~5 minutes at 1/sec

    /// Record an RF sample from LOG_RX_DATA.
    func recordRFSample(snr: Int8, rssi: Int8) {
        guard isMonitoring else { return }
        let sample = RFSample(
            timestamp: Date(),
            snr: Double(snr) / 4.0,
            rssi: rssi
        )
        rfSamples.append(sample)
        if rfSamples.count > maxRFSamples {
            rfSamples.removeFirst(rfSamples.count - maxRFSamples)
        }
    }

    /// Clear RF samples.
    func clearRFSamples() {
        rfSamples.removeAll()
    }

    /// Start/stop monitoring.
    func toggleMonitoring() {
        isMonitoring.toggle()
        if isMonitoring {
            rfSamples.removeAll()
        }
    }

    // MARK: - Stats

    var averageSNR: Double? {
        guard !rfSamples.isEmpty else { return nil }
        return rfSamples.map(\.snr).reduce(0, +) / Double(rfSamples.count)
    }

    var averageRSSI: Double? {
        guard !rfSamples.isEmpty else { return nil }
        return rfSamples.map { Double($0.rssi) }.reduce(0, +) / Double(rfSamples.count)
    }

    var peakSNR: Double? {
        rfSamples.map(\.snr).max()
    }

    var minRSSI: Int8? {
        rfSamples.map(\.rssi).min()
    }
}
