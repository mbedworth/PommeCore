//
//  ContactBackupStore.swift
//  PommeCore
//
//  Reads and writes contact snapshots on disk.
//
//  The decision logic and the Codable contract live in MeshCoreKit's
//  ContactBackup, where tests can reach them; this is the thin filesystem
//  layer around it.
//
//  Created by Michael P. Bedworth on 10/03/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import Foundation
import os.log
import MeshCoreKit

/// On-disk store of contact snapshots.
@MainActor
@Observable
final class ContactBackupStore {

    private static let logger = Logger(subsystem: "com.pommecore", category: "ContactBackup")

    /// Snapshots on disk, newest first.
    private(set) var backups: [ContactBackup] = []

    /// Set while a restore is sending frames, so the UI can show progress and
    /// refuse to start a second one.
    private(set) var restoreProgress: (sent: Int, total: Int)?

    private static var directory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeshCore/ContactBackups", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: - Loading

    func load() {
        let dir = Self.directory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else {
            backups = []
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded: [ContactBackup] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let backup = try? decoder.decode(ContactBackup.self, from: data) else {
                // A single unreadable file must not hide the others.
                Self.logger.warning("Skipped unreadable contact backup: \(file.lastPathComponent)")
                continue
            }
            loaded.append(backup)
        }
        backups = loaded.sorted { $0.createdAt > $1.createdAt }
        Self.logger.info("Loaded \(self.backups.count) contact backups")
    }

    /// Snapshots for one radio, newest first.
    func backups(forRadio radioKeyHex: String) -> [ContactBackup] {
        backups.filter { $0.belongs(toRadio: radioKeyHex) }
    }

    // MARK: - Writing

    /// Write a snapshot, returning whether it was stored.
    ///
    /// Synchronous on purpose. The caller is about to do something
    /// irreversible, so the backup must be on disk *before* the first frame
    /// goes out — handing this to a detached task would race the deletion it
    /// exists to protect against. A contact list is a few kilobytes, so the
    /// cost is a single small write.
    @discardableResult
    func write(_ backup: ContactBackup) -> Bool {
        guard !backup.contacts.isEmpty else {
            Self.logger.info("Not writing an empty contact backup")
            return false
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        let stamp = ISO8601DateFormatter().string(from: backup.createdAt)
            .replacingOccurrences(of: ":", with: "-")
        let url = Self.directory.appendingPathComponent("contacts-\(stamp).json")

        do {
            let data = try encoder.encode(backup)
            try data.write(to: url, options: .atomic)
            backups.insert(backup, at: 0)
            backups.sort { $0.createdAt > $1.createdAt }
            prune()
            Self.logger.info("Wrote contact backup: \(backup.contacts.count) contacts — \(backup.reason)")
            DebugLogger.shared.log("Backed up \(backup.contacts.count) contacts before \(backup.reason)", level: .info)
            return true
        } catch {
            Self.logger.error("Failed to write contact backup: \(error.localizedDescription)")
            DebugLogger.shared.log("Could not back up contacts: \(error.localizedDescription)", level: .warning)
            return false
        }
    }

    private func prune() {
        let doomed = ContactBackupRetention.filesToPrune(backups, date: \.createdAt)
        guard !doomed.isEmpty else { return }
        let stamps = Set(doomed.map(\.createdAt))
        for backup in doomed {
            let stamp = ISO8601DateFormatter().string(from: backup.createdAt)
                .replacingOccurrences(of: ":", with: "-")
            let url = Self.directory.appendingPathComponent("contacts-\(stamp).json")
            try? FileManager.default.removeItem(at: url)
        }
        backups.removeAll { stamps.contains($0.createdAt) }
    }

    func delete(_ backup: ContactBackup) {
        let stamp = ISO8601DateFormatter().string(from: backup.createdAt)
            .replacingOccurrences(of: ":", with: "-")
        try? FileManager.default.removeItem(
            at: Self.directory.appendingPathComponent("contacts-\(stamp).json")
        )
        backups.removeAll { $0.createdAt == backup.createdAt }
    }

    // MARK: - Restore

    /// Mark a restore as running, so the UI can show progress and refuse to
    /// start a second one.
    ///
    /// The sending itself belongs to `ContactStore.addContacts`, which paces
    /// the frames, stops if the link drops, and checks against the radio's own
    /// list afterwards. This store used to send them directly and assume every
    /// frame arrived — the same assumption that lost 4 of 11 contacts on a
    /// profile import when BLE dropped mid-burst.
    func beginRestore(count: Int) {
        restoreProgress = (sent: 0, total: count)
        Self.logger.info("Restoring \(count) contacts")
        DebugLogger.shared.log("Restoring \(count) contacts from backup", level: .tx)
    }

    func endRestore() {
        restoreProgress = nil
        DebugLogger.shared.log("Contact restore finished", level: .info)
    }

    var isRestoring: Bool { restoreProgress != nil }
}
