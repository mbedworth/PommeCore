//
//  RFMonitorStore.swift
//  PommeCore
//
//  Stores telemetry history and noise floor (SNR/RSSI) readings for charts.
//

import Foundation
import MeshCoreKit

/// A timestamped telemetry snapshot for history charts.
struct TelemetrySnapshot: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let readings: [CodableTelemetryReading]

    init(timestamp: Date, readings: [TelemetryReading]) {
        self.id = UUID()
        self.timestamp = timestamp
        self.readings = readings.map { CodableTelemetryReading(name: $0.name, value: $0.value, unit: $0.unit) }
    }

    func value(named name: String) -> Double? {
        readings.first(where: { $0.name == name })?.value
    }

    func toTelemetryReadings() -> [TelemetryReading] {
        readings.map { TelemetryReading(name: $0.name, value: $0.value, unit: $0.unit) }
    }
}

/// Codable wrapper for TelemetryReading (which uses non-stable UUID id).
struct CodableTelemetryReading: Codable, Identifiable {
    let id: UUID
    let name: String
    let value: Double
    let unit: String

    init(name: String, value: Double, unit: String) {
        self.id = UUID()
        self.name = name
        self.value = value
        self.unit = unit
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

    /// Telemetry history per contact (keyed by publicKeyPrefix hex).
    /// Stores up to maxHistoryCount snapshots per contact.
    var telemetryHistory: [Data: [TelemetrySnapshot]] = [:]

    private let maxHistoryCount = 500
    private let maxDaysRetained = 7
    private var savePending = false

    /// Cloud sync hook — called after recording telemetry and after saving.
    var cloudSync: TelemetryCloudSync?

    /// Record a new telemetry reading for a contact.
    func recordTelemetry(for contactKey: Data, readings: [TelemetryReading]) {
        let snapshot = TelemetrySnapshot(timestamp: Date(), readings: readings)
        var history = telemetryHistory[contactKey] ?? []
        history.append(snapshot)
        if history.count > maxHistoryCount {
            history.removeFirst(history.count - maxHistoryCount)
        }
        telemetryHistory[contactKey] = history
        cloudSync?.markDirty(contactKey: contactKey)
        scheduleSave()
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

    // MARK: - Persistence

    private static var telemetryFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = dir.appendingPathComponent("MeshCore", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("telemetry_history.json")
    }

    /// Codable wrapper for serialization (Data keys become hex strings).
    private struct PersistedHistory: Codable {
        let contacts: [String: [TelemetrySnapshot]]
    }

    /// Clear all telemetry history (local file + in-memory).
    func clearTelemetryHistory() {
        telemetryHistory.removeAll()
        try? FileManager.default.removeItem(at: Self.telemetryFileURL)
        DebugLogger.shared.log("TELEMETRY: cleared all history", level: .info)
    }

    /// Number of telemetry snapshots across all contacts.
    var totalSnapshotCount: Int {
        telemetryHistory.values.reduce(0) { $0 + $1.count }
    }

    func loadTelemetryHistory() {
        let url = Self.telemetryFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let persisted = try JSONDecoder().decode(PersistedHistory.self, from: data)
            let cutoff = Date().addingTimeInterval(-Double(maxDaysRetained) * 86400)
            for (hexKey, snapshots) in persisted.contacts {
                if let keyData = Data(hexString: hexKey) {
                    telemetryHistory[keyData] = snapshots.filter { $0.timestamp > cutoff }
                }
            }
        } catch {
            DebugLogger.shared.log("TELEMETRY: failed to load history: \(error.localizedDescription)", level: .warning)
        }
    }

    private func scheduleSave() {
        guard !savePending else { return }
        savePending = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000) // batch saves every 5s
            self.savePending = false
            self.saveTelemetryHistory()
        }
    }

    func saveTelemetryHistory() {
        let cutoff = Date().addingTimeInterval(-Double(maxDaysRetained) * 86400)
        var contacts: [String: [TelemetrySnapshot]] = [:]
        for (key, snapshots) in telemetryHistory {
            let filtered = snapshots.filter { $0.timestamp > cutoff }
            if !filtered.isEmpty {
                contacts[key.map { String(format: "%02x", $0) }.joined()] = filtered
            }
        }
        let persisted = PersistedHistory(contacts: contacts)
        do {
            let data = try JSONEncoder().encode(persisted)
            try data.write(to: Self.telemetryFileURL, options: .atomic)
        } catch {
            DebugLogger.shared.log("TELEMETRY: failed to save history: \(error.localizedDescription)", level: .warning)
        }
        cloudSync?.uploadIfNeeded(telemetryHistory: telemetryHistory)
    }
}
